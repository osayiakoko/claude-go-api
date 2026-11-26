# HTTP kit: response envelope, errors, pagination, request reading, validation, formatting

Dependencies: `github.com/go-playground/validator/v10`, `github.com/go-playground/form/v4`,
`github.com/nyaruka/phonenumbers`, `github.com/shopspring/decimal`.

## Response envelope — `internal/shared/response/response.go`

```go
type successBody struct {
	Success bool `json:"success"`
	Data    any  `json:"data"`
}
type errorDetail struct {
	Code    string `json:"code"`
	Message any    `json:"message"` // string, or map[field]message for validation
}
type errorBody struct {
	Success bool        `json:"success"`
	Error   errorDetail `json:"error"`
}

func Ok(w http.ResponseWriter, data any)      { writeJSON(w, http.StatusOK, successBody{true, data}) }
func Created(w http.ResponseWriter, data any) { writeJSON(w, http.StatusCreated, successBody{true, data}) }
func NoContent(w http.ResponseWriter)         { w.WriteHeader(http.StatusNoContent) }

func writeError(w http.ResponseWriter, status int, code string, msg any) {
	writeJSON(w, status, errorBody{false, errorDetail{code, msg}})
}

func BadRequest(w http.ResponseWriter, _ *http.Request, err error) { writeError(w, 400, "BAD_REQUEST", err.Error()) }
func FailedValidation(w http.ResponseWriter, _ *http.Request, errs map[string]string) {
	writeError(w, 422, "VALIDATION_ERROR", errs)
}
func NotFound(w http.ResponseWriter, _ *http.Request, err error)  { writeError(w, 404, "NOT_FOUND", msgOr(err, "the requested resource could not be found")) }
func Conflict(w http.ResponseWriter, _ *http.Request, err error)  { writeError(w, 409, "CONFLICT", msgOr(err, "the resource was changed by another request; retry")) }
func Forbidden(w http.ResponseWriter, _ *http.Request, err error) { writeError(w, 403, "FORBIDDEN", msgOr(err, "you do not have permission to perform this action")) }
func ServerError(w http.ResponseWriter, _ *http.Request, _ error) {
	writeError(w, 500, "INTERNAL_SERVER_ERROR", "the server encountered a problem and could not process your request")
}
// Also: Unauthorized, InvalidAuthenticationToken (401 INVALID_TOKEN + WWW-Authenticate: Bearer),
// ExpiredAuthenticationToken (401 TOKEN_EXPIRED), InvalidAPIKey (401), MethodNotAllowed (405),
// RateLimitExceeded (429). Distinct codes let mobile clients decide refresh vs logout.

func msgOr(err error, fallback string) string {
	if err != nil {
		return err.Error()
	}
	return fallback
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(append(b, '\n'))
}
```

## Single error-mapping point — `response/errors.go`

```go
func HandleError(w http.ResponseWriter, r *http.Request, err error) {
	var (
		notFound   *shareddomain.ErrNotFound
		duplicate  *shareddomain.ErrDuplicate
		conflict   *shareddomain.ErrConflict
		validation *shareddomain.ErrValidation
		unauth     *shareddomain.ErrUnauthorised
	)
	switch {
	case errors.As(err, &notFound):
		NotFound(w, r, err)
	case errors.As(err, &duplicate), errors.As(err, &conflict):
		Conflict(w, r, err)
	case errors.As(err, &validation):
		BadRequest(w, r, err)
	case errors.As(err, &unauth):
		Forbidden(w, r, err)
	default:
		captureInternalError(r, err) // real cause goes to the log, not the client
		ServerError(w, r, err)
	}
}
```

`ErrConflict{Resource}` = optimistic-lock/version conflict ("changed by another request").

### Internal error capture — `response/internal_error.go`

The request logger puts a slot in ctx; `HandleError` fills it; the logger includes the real
error in the 5xx log line while the client sees a generic message.

```go
type internalErrKey struct{}

func WithInternalErrorCapture(ctx context.Context) (context.Context, func() error) {
	var captured error
	return context.WithValue(ctx, internalErrKey{}, &captured), func() error { return captured }
}

func captureInternalError(r *http.Request, err error) {
	if p, ok := r.Context().Value(internalErrKey{}).(*error); ok {
		*p = err
	}
}
```

## Pagination — `response/paginated.go`

Always return the same shape (mobile clients break on missing keys):

```go
type Page[T any] struct {
	Results      []T `json:"results"` // never null: always [] when empty
	CurrentPage  int `json:"currentPage"`
	PageSize     int `json:"pageSize"`
	LastPage     int `json:"lastPage"`
	TotalRecords int `json:"totalRecords"`
}

func NewPage[T any](items []T, total, page, pageSize int) Page[T] {
	if items == nil {
		items = []T{}
	}
	last := 0
	if pageSize > 0 && total > 0 {
		last = (total + pageSize - 1) / pageSize
	}
	return Page[T]{Results: items, CurrentPage: page, PageSize: pageSize, LastPage: last, TotalRecords: total}
}
```

Repos return `(items, total, err)` using `LIMIT $n OFFSET $m` + `COUNT(*) OVER()` (one query).
Clamp `pageSize` (e.g. 1–100, default 20). For large/fast-moving tables prefer keyset
pagination (`WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC`).

## Reading requests — `internal/shared/httpx/read.go`

```go
const maxBodyBytes = 1 << 20

// ReadJSON: 1MB cap, unknown fields rejected, exactly one JSON value, friendly errors.
func ReadJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	if err := dec.Decode(dst); err != nil {
		var syntaxErr *json.SyntaxError
		var typeErr *json.UnmarshalTypeError
		var maxErr *http.MaxBytesError
		switch {
		case errors.As(err, &syntaxErr):
			return fmt.Errorf("body contains badly-formed JSON (at character %d)", syntaxErr.Offset)
		case errors.Is(err, io.ErrUnexpectedEOF):
			return errors.New("body contains badly-formed JSON")
		case errors.As(err, &typeErr):
			if typeErr.Field != "" {
				return fmt.Errorf("body contains incorrect JSON type for field %q", typeErr.Field)
			}
			return fmt.Errorf("body contains incorrect JSON type (at character %d)", typeErr.Offset)
		case errors.Is(err, io.EOF):
			return errors.New("body must not be empty")
		case strings.HasPrefix(err.Error(), "json: unknown field "):
			return fmt.Errorf("body contains unknown key %s", strings.TrimPrefix(err.Error(), "json: unknown field "))
		case errors.As(err, &maxErr):
			return fmt.Errorf("body must not be larger than %d bytes", maxBodyBytes)
		default:
			return err
		}
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("body must only contain a single JSON value")
	}
	return nil
}

var queryDecoder = form.NewDecoder()

// ReadQuery decodes query params into a struct using `form:"..."` tags, then validate it.
func ReadQuery(r *http.Request, dst any) error { return queryDecoder.Decode(dst, r.URL.Query()) }
```

List DTO example:

```go
type ListDebtsQuery struct {
	Page     int    `form:"page"     validate:"omitempty,min=1"`
	PageSize int    `form:"pageSize" validate:"omitempty,min=1,max=100"`
	Status   string `form:"status"   validate:"omitempty,oneof=open settled"`
	Sort     string `form:"sort"     validate:"omitempty,sortsafelist"`
}

func (ListDebtsQuery) SortSafelist() []string {
	return []string{"created_at", "-created_at", "amount", "-amount"}
}
```

The safelisted sort value maps to a hard-coded `ORDER BY` fragment in the repo — never
interpolate user input into SQL.

## Validator — `internal/shared/validator/validator.go` (stateless, concurrency-safe)

One `*Validator` is shared by every handler, so it must hold **no per-request state**.
`Validate` returns the errors; it never stores them on the struct.

```go
type Validator struct{ v *validator.Validate }

// New builds the validator once at startup (container) and is safe for concurrent use.
func New(phoneRegions []string) *Validator {
	v := validator.New(validator.WithRequiredStructEnabled())
	v.RegisterTagNameFunc(func(f reflect.StructField) string { // use JSON/form names in messages
		for _, tag := range []string{"json", "form"} {
			if name := strings.SplitN(f.Tag.Get(tag), ",", 2)[0]; name != "" && name != "-" {
				return name
			}
		}
		return f.Name
	})
	_ = v.RegisterValidation("phone", func(fl validator.FieldLevel) bool {
		return phone.IsValid(fl.Field().String(), phoneRegions)
	})
	_ = v.RegisterValidation("decimal_positive", func(fl validator.FieldLevel) bool {
		d, ok := fl.Field().Interface().(decimal.Decimal)
		return ok && d.IsPositive()
	})
	_ = v.RegisterValidation("sortsafelist", func(fl validator.FieldLevel) bool {
		p, ok := fl.Parent().Interface().(interface{ SortSafelist() []string })
		return ok && slices.Contains(p.SortSafelist(), fl.Field().String())
	})
	return &Validator{v: v}
}

// Validate returns field → message, or nil when the input is valid.
func (val *Validator) Validate(input any) map[string]string {
	err := val.v.Struct(input)
	if err == nil {
		return nil
	}
	var verrs validator.ValidationErrors
	if !errors.As(err, &verrs) {
		return map[string]string{"_": err.Error()}
	}
	out := make(map[string]string, len(verrs))
	for _, e := range verrs {
		if _, seen := out[e.Field()]; !seen {
			out[e.Field()] = message(e)
		}
	}
	return out
}

func message(e validator.FieldError) string {
	f, p := e.Field(), e.Param()
	switch e.Tag() {
	case "required":
		return f + " is a required field"
	case "min":
		return fmt.Sprintf("%s must be a minimum of %s", f, p)
	case "max":
		return fmt.Sprintf("%s must be a maximum of %s", f, p)
	case "len":
		return fmt.Sprintf("%s must be %s characters long", f, p)
	case "email":
		return f + " must be a valid email address"
	case "url":
		return f + " must be a valid URL"
	case "uuid":
		return f + " must be a valid UUID"
	case "oneof":
		return fmt.Sprintf("%s must be one of %s", f, p)
	case "datetime":
		return fmt.Sprintf("%s must follow %s format", f, p)
	case "eqfield":
		return fmt.Sprintf("%s must be the same as %s", f, p)
	case "decimal_positive":
		return f + " must be a positive amount"
	case "phone":
		return f + " must be a valid phone number"
	case "sortsafelist":
		return f + " is an invalid value"
	default:
		return f + " is invalid"
	}
}
```

Handler use:

```go
if errs := h.validator.Validate(input); errs != nil {
	response.FailedValidation(w, r, errs)
	return
}
```

## Phone numbers — `internal/shared/phone/phone.go`

Regions come from config (`PHONE_SUPPORTED_REGIONS=NG,GH,KE`), never hard-coded.

```go
func IsValid(p string, regions []string) bool { _, err := Normalize(p, regions); return err == nil }

// Normalize returns E.164 (+2348012345678). Always store and look up the normalised form.
func Normalize(p string, regions []string) (string, error) {
	for _, region := range regions {
		num, err := phonenumbers.Parse(p, region)
		if err == nil && phonenumbers.IsValidNumberForRegion(num, region) {
			return phonenumbers.Format(num, phonenumbers.E164), nil
		}
	}
	return "", errors.New("phone number is not valid for any supported region")
}

// Mask for logs/messages: +234****5678.
func Mask(e164 string) string {
	if len(e164) < 8 {
		return "****"
	}
	return e164[:4] + "****" + e164[len(e164)-4:]
}
```

## Money formatting — no float conversion

```go
// FormatMoney renders 1234567.5 → "1,234,567.50" without converting to float64.
func FormatMoney(d decimal.Decimal) string {
	s := d.Abs().StringFixed(2) // "1234567.50"
	intPart, frac, _ := strings.Cut(s, ".")
	var b strings.Builder
	if d.IsNegative() {
		b.WriteByte('-')
	}
	for i, c := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	b.WriteByte('.')
	b.WriteString(frac)
	return b.String()
}
```

In JSON, send amounts as strings (`"amount": "5000.00"`) so no client parses them as floats.
Read money from query strings with `decimal.NewFromString`, never `strconv.ParseFloat`.
