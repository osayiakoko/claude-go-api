# Canonical shapes (example resource: `product`)

Replace `example.com/app` with the module path from `go.mod`.

## Domain

```go
package domain

import (
	shareddomain "example.com/app/internal/core/shared/domain"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

type ProductStatus string

const (
	ProductStatusActive   ProductStatus = "active"
	ProductStatusArchived ProductStatus = "archived"
)

type Product struct {
	shareddomain.BaseEntity
	AccountID uuid.UUID
	Name      string
	Price     decimal.Decimal
	Status    ProductStatus
}

func (p *Product) IsArchived() bool { return p.Status == ProductStatusArchived }
```

## Ports

```go
package repositories

type ProductRepository interface {
	// Create persists a new product. Returns *ErrDuplicate if the name is taken in the account.
	Create(ctx context.Context, p *domain.Product) error
	// GetByID returns *ErrNotFound if no product has the id.
	GetByID(ctx context.Context, id uuid.UUID) (*domain.Product, error)
	ListByAccount(ctx context.Context, accountID uuid.UUID, f shareddomain.Filters) ([]*domain.Product, int, error)
	Update(ctx context.Context, p *domain.Product) error
	Delete(ctx context.Context, id uuid.UUID) error
}
```

## Service

```go
package services

type productService struct {
	repo productrepos.ProductRepository
	tx   sharedports.Transactor
}

func NewProductService(repo productrepos.ProductRepository, tx sharedports.Transactor) productsvc.ProductService {
	return &productService{repo: repo, tx: tx}
}

func (s *productService) Archive(ctx context.Context, id, accountID uuid.UUID) error {
	p, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return err // already a domain error
	}
	if p.AccountID != accountID {
		return &shareddomain.ErrUnauthorised{Reason: "you do not have permission to modify this product"}
	}
	if p.IsArchived() {
		return &shareddomain.ErrValidation{Field: "status", Message: "product is already archived"}
	}
	p.Status = productdomain.ProductStatusArchived
	p.UpdatedAt = time.Now()
	if err := s.repo.Update(ctx, p); err != nil {
		return fmt.Errorf("archive product: %w", err)
	}
	return nil
}
```

## Postgres repository

```go
package postgres

var _ productrepos.ProductRepository = (*productRepository)(nil)

type productRepository struct{ pool *pgxpool.Pool }

func NewProductRepository(pool *pgxpool.Pool) productrepos.ProductRepository {
	return &productRepository{pool: pool}
}

func (r *productRepository) Create(ctx context.Context, p *productdomain.Product) error {
	q := getQuerier(ctx, r.pool)
	_, err := q.Exec(ctx, `
		INSERT INTO products (id, account_id, name, price, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
	`, p.ID, p.AccountID, p.Name, p.Price, p.Status, p.CreatedAt, p.UpdatedAt)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return &shareddomain.ErrDuplicate{Resource: "product", Field: "name"}
	}
	return err
}

func (r *productRepository) GetByID(ctx context.Context, id uuid.UUID) (*productdomain.Product, error) {
	q := getQuerier(ctx, r.pool)
	row := q.QueryRow(ctx, `
		SELECT id, account_id, name, price, status, created_at, updated_at
		FROM products WHERE id = $1
	`, id)
	return scanProduct(row)
}

func (r *productRepository) Delete(ctx context.Context, id uuid.UUID) error {
	q := getQuerier(ctx, r.pool)
	tag, err := q.Exec(ctx, `DELETE FROM products WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return &shareddomain.ErrNotFound{Resource: "product"}
	}
	return nil
}

func scanProduct(row pgx.Row) (*productdomain.Product, error) {
	var p productdomain.Product
	err := row.Scan(&p.ID, &p.AccountID, &p.Name, &p.Price, &p.Status, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &shareddomain.ErrNotFound{Resource: "product"}
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}
```

## Memory repository

```go
package memory

var _ productrepos.ProductRepository = (*productRepository)(nil)

type productRepository struct {
	mu    sync.RWMutex
	items map[uuid.UUID]*productdomain.Product
}

func NewProductRepository() productrepos.ProductRepository {
	return &productRepository{items: make(map[uuid.UUID]*productdomain.Product)}
}

func (r *productRepository) GetByID(_ context.Context, id uuid.UUID) (*productdomain.Product, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.items[id]
	if !ok {
		return nil, &shareddomain.ErrNotFound{Resource: "product"}
	}
	cp := *p // return a copy so callers can't mutate stored state
	return &cp, nil
}
```

## DTO

```go
package dto

type CreateProductRequest struct {
	Name  string `json:"name"  validate:"required,min=2,max=100"`
	Price string `json:"price" validate:"required,decimal_positive"`
}

type ProductResponse struct {
	ID        uuid.UUID `json:"id"`
	Name      string    `json:"name"`
	Price     string    `json:"price"` // decimal as string — no float precision loss
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"createdAt"`
}

func ToProductResponse(p *productdomain.Product) ProductResponse {
	return ProductResponse{ID: p.ID, Name: p.Name, Price: p.Price.StringFixed(2),
		Status: string(p.Status), CreatedAt: p.CreatedAt}
}
```

## Handler

```go
// CreateProduct godoc
// @Summary   Create product
// @Tags      Products
// @Security  BearerAuth
// @Accept    json
// @Produce   json
// @Param     input body dto.CreateProductRequest true "Product"
// @Success   201 {object} dto.ProductResponse
// @Router    /products [post]
func (h *ProductHandler) CreateProduct(w http.ResponseWriter, r *http.Request) {
	var input dto.CreateProductRequest
	if err := helpers.ReadJSON(w, r, &input); err != nil {
		response.BadRequest(w, r, err)
		return
	}
	h.validator.Validate(input)
	if !h.validator.Valid() {
		response.FailedValidation(w, r, h.validator.Errors)
		return
	}

	userID := auth.GetUserID(r)
	p, err := h.productService.Create(r.Context(), userID, input.Name, decimal.RequireFromString(input.Price))
	if err != nil {
		response.HandleError(w, r, err)
		return
	}
	response.Created(w, dto.ToProductResponse(p))
}
```

## Service test

```go
package services_test

func newProductService() productsvc.ProductService {
	// memory.NewTransactor is a no-op Transactor whose WithTx just calls fn(ctx).
	return services.NewProductService(memory.NewProductRepository(), memory.NewTransactor())
}

func TestProductService_Archive_OtherAccount_ReturnsErrUnauthorised(t *testing.T) {
	svc := newProductService()
	ctx := context.Background()
	owner, other := uuid.New(), uuid.New()

	p, err := svc.Create(ctx, owner, "Rice", decimal.NewFromInt(5000))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	err = svc.Archive(ctx, p.ID, other)
	var unauth *shareddomain.ErrUnauthorised
	if !errors.As(err, &unauth) {
		t.Fatalf("expected *ErrUnauthorised, got %T: %v", err, err)
	}
}
```
