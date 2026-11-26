# External providers (SMS, WhatsApp, payments, LLMs, KYC)

## Port in core, adapter outside

```go
// core/shared/ports/external/sms_service.go
type SMSService interface {
	Send(ctx context.Context, to, message string) error
}

// core/shared/ports/external/payment_provider.go
type PaymentProvider interface {
	InitializePayment(ctx context.Context, in InitializePaymentInput) (*InitializePaymentResult, error)
	VerifyPayment(ctx context.Context, reference string) (*PaymentStatus, error)
	ParseWebhook(r *http.Request) (*PaymentWebhookPayload, error) // verifies signature
}
```

Core defines provider-neutral types (`InitializePaymentInput`, `PaymentStatus`); each adapter
maps to/from its vendor's JSON. Swapping Paystack ↔ Flutterwave is a container change.

## Adapter — `adapters/secondary/external/<provider>/client.go`

```go
var _ external.SMSService = (*termiiClient)(nil)

type termiiClient struct {
	http    *http.Client
	baseURL string
	apiKey  string
	sender  string
	metrics *metrics.ExternalMetrics
}

func NewTermiiClient(cfg config.SMSConfig, m *metrics.ExternalMetrics) external.SMSService {
	return &termiiClient{
		http:    &http.Client{Timeout: 10 * time.Second}, // ALWAYS set a timeout
		baseURL: "https://api.ng.termii.com",
		apiKey:  cfg.APIKey, sender: cfg.SenderID, metrics: m,
	}
}

func (c *termiiClient) Send(ctx context.Context, to, msg string) error {
	start := time.Now()
	defer c.metrics.Observe(metrics.ProviderSMS, metrics.OpSend, start)

	body, _ := json.Marshal(map[string]string{"to": to, "from": c.sender, "sms": msg,
		"type": "plain", "channel": "generic", "api_key": c.apiKey})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/sms/send", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		c.metrics.IncError(metrics.ProviderSMS, metrics.OpSend)
		return fmt.Errorf("termii send: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		c.metrics.IncError(metrics.ProviderSMS, metrics.OpSend)
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("termii send: status %d: %s", resp.StatusCode, b) // no secrets in errors
	}
	return nil
}
```

Rules:
- Context on every request; client timeout always set; read error bodies with a size limit.
- Never log request bodies that contain API keys, BVN, card data or OTPs.
- Retries: only for idempotent calls or with an idempotency key the provider honours; use
  exponential backoff with jitter and a cap. Better: do the call from a River job / Temporal
  activity and let it own retries.
- Money movement: always send your own unique reference (e.g. `disb-<loanID>`), store it
  before calling, and reconcile with `VerifyPayment` — never trust only the synchronous response.

## Real vs mock by environment — `container/external.go`

```go
var sms external.SMSService = mock.NewSMSService(log) // logs instead of sending
if cfg.Env.IsProductionLike() && cfg.SMS.APIKey != "" {
	sms = termii.NewTermiiClient(cfg.SMS, extMetrics)
}
```

Mocks live in `adapters/secondary/external/mock/` and are also used by tests. Log at startup
which implementation was chosen for each provider. In production, fail fast at startup if a
required provider key is missing instead of silently using a mock.

## Inbound webhooks (payments, WhatsApp)

1. **Verify the signature** over the raw body with the provider's secret, using
   `hmac.Equal` / `subtle.ConstantTimeCompare` (Paystack: HMAC-SHA512 in `x-paystack-signature`;
   Flutterwave: `verif-hash` header equals your secret; Meta: HMAC-SHA256 in
   `X-Hub-Signature-256`). Reject before parsing JSON.
2. **Deduplicate**: providers retry. Store the provider event/message ID in a table with a
   unique constraint (`INSERT ... ON CONFLICT DO NOTHING`); if no row was inserted, return 200
   and stop.
3. **Acknowledge fast**: persist / enqueue (River `InsertTx` in the same tx as the dedup row),
   return 200, process asynchronously. Slow handlers cause provider retries and duplicates.
4. **Don't trust the payload for amounts**: confirm with `VerifyPayment(reference)` and check
   amount + currency against your own record before crediting anything.
5. Clean up old dedup rows with a ticker worker (e.g. older than 7 days).

```go
func verifyPaystack(body []byte, sigHex, secret string) bool {
	mac := hmac.New(sha512.New, []byte(secret))
	mac.Write(body)
	expected := mac.Sum(nil)
	got, err := hex.DecodeString(sigHex)
	return err == nil && hmac.Equal(got, expected)
}
```

## LLM providers

Put LLM calls behind a port too (e.g. `MessageParser`), try cheap deterministic logic first and
fall back to the LLM only when it can't decide, set a short timeout, cap tokens, and record
latency/error metrics per model. Never send secrets or full account numbers in prompts.
