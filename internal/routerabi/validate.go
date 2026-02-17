package routerabi

import (
	"errors"
	"fmt"
)

const ABIVersionV0 = "visitor-router-abi-v0"

const (
	ExportMemory             = "memory"
	ExportInputPtr           = "input_ptr"
	ExportInputCap           = "input_cap"
	ExportRoute              = "route"
	ExportETagPtr            = "etag_ptr"
	ExportETagLen            = "etag_len"
	ExportContentTypePtr     = "content_type_ptr"
	ExportContentTypeLen     = "content_type_len"
	ExportContentSHA256Ptr   = "content_sha256_ptr"
	ExportContentSHA256Count = "content_sha256_count"
	ExportRecipeSHA256Ptr    = "recipe_sha256_ptr"
	ExportRecipeSHA256Count  = "recipe_sha256_count"
	ExportLocationPtr        = "location_ptr"
	ExportLocationLen        = "location_len"
)

const SHA256DigestBytes uint64 = 32

var (
	ErrMissingExport      = errors.New("missing export")
	ErrInputTooLarge      = errors.New("input too large")
	ErrOutOfBounds        = errors.New("out of bounds")
	ErrInvalidDigestCount = errors.New("invalid digest count")
	ErrInvalidRedirect    = errors.New("invalid redirect")
	ErrRouterInternal     = errors.New("router internal")
)

var RequiredExportsV0 = []string{
	ExportMemory,
	ExportInputPtr,
	ExportInputCap,
	ExportRoute,
	ExportETagPtr,
	ExportETagLen,
	ExportContentTypePtr,
	ExportContentTypeLen,
	ExportContentSHA256Ptr,
	ExportContentSHA256Count,
	ExportRecipeSHA256Ptr,
	ExportRecipeSHA256Count,
	ExportLocationPtr,
	ExportLocationLen,
}

type routeResultViewV0 struct {
	Status             int32
	ETagPtr            int32
	ETagLen            int32
	ContentTypePtr     int32
	ContentTypeLen     int32
	ContentSHA256Ptr   int32
	ContentSHA256Count int32
	RecipeSHA256Ptr    int32
	RecipeSHA256Count  int32
	LocationPtr        int32
	LocationLen        int32
}

func isRedirectStatus(status int32) bool {
	return status >= 300 && status <= 399
}

func missingExportError(name string) error {
	return fmt.Errorf("%w: %s", ErrMissingExport, name)
}

func validateRouteResultV0(memorySize uint32, result routeResultViewV0) error {
	if err := validateRegion(memorySize, result.ETagPtr, result.ETagLen, "etag"); err != nil {
		return err
	}
	if err := validateRegion(memorySize, result.ContentTypePtr, result.ContentTypeLen, "content_type"); err != nil {
		return err
	}
	if err := validateDigestRegion(memorySize, result.ContentSHA256Ptr, result.ContentSHA256Count, "content_sha256"); err != nil {
		return err
	}
	if err := validateDigestRegion(memorySize, result.RecipeSHA256Ptr, result.RecipeSHA256Count, "recipe_sha256"); err != nil {
		return err
	}
	if err := validateRegion(memorySize, result.LocationPtr, result.LocationLen, "location"); err != nil {
		return err
	}
	if isRedirectStatus(result.Status) && result.LocationLen <= 0 {
		return fmt.Errorf("%w: status=%d location_len=%d", ErrInvalidRedirect, result.Status, result.LocationLen)
	}
	return nil
}

func validateDigestRegion(memorySize uint32, ptr int32, count int32, field string) error {
	if count < 0 {
		return fmt.Errorf("%w: %s_count=%d", ErrInvalidDigestCount, field, count)
	}

	byteLen := uint64(count) * SHA256DigestBytes
	if count > 0 && byteLen/SHA256DigestBytes != uint64(count) {
		return fmt.Errorf("%w: %s_count=%d", ErrInvalidDigestCount, field, count)
	}

	return validateRegionU64(memorySize, ptr, byteLen, field)
}

func validateRegion(memorySize uint32, ptr int32, length int32, field string) error {
	if length < 0 {
		return fmt.Errorf("%w: %s_len=%d", ErrOutOfBounds, field, length)
	}
	return validateRegionU64(memorySize, ptr, uint64(length), field)
}

func validateRegionU64(memorySize uint32, ptr int32, length uint64, field string) error {
	if ptr < 0 {
		return fmt.Errorf("%w: %s_ptr=%d", ErrOutOfBounds, field, ptr)
	}

	start := uint64(ptr)
	end := start + length
	if end < start {
		return fmt.Errorf("%w: %s ptr=%d len=%d", ErrOutOfBounds, field, ptr, length)
	}
	if end > uint64(memorySize) {
		return fmt.Errorf("%w: %s ptr=%d len=%d memory_size=%d", ErrOutOfBounds, field, ptr, length, memorySize)
	}
	return nil
}
