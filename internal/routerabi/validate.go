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
	ExportETagSize           = "etag_size"
	ExportContentTypePtr     = "content_type_ptr"
	ExportContentTypeSize    = "content_type_size"
	ExportContentSHA256Ptr   = "content_sha256_ptr"
	ExportContentSHA256Count = "content_sha256_count"
	ExportRecipeSHA256Ptr    = "recipe_sha256_ptr"
	ExportRecipeSHA256Count  = "recipe_sha256_count"
	ExportLocationPtr        = "location_ptr"
	ExportLocationSize       = "location_size"
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
	ExportETagSize,
	ExportContentTypePtr,
	ExportContentTypeSize,
	ExportContentSHA256Ptr,
	ExportContentSHA256Count,
	ExportRecipeSHA256Ptr,
	ExportRecipeSHA256Count,
	ExportLocationPtr,
	ExportLocationSize,
}

type routeResultViewV0 struct {
	Status             int32
	ETagPtr            int32
	ETagSize           int32
	ContentTypePtr     int32
	ContentTypeSize    int32
	ContentSHA256Ptr   int32
	ContentSHA256Count int32
	RecipeSHA256Ptr    int32
	RecipeSHA256Count  int32
	LocationPtr        int32
	LocationSize       int32
}

func isRedirectStatus(status int32) bool {
	return status >= 300 && status <= 399
}

func missingExportError(name string) error {
	return fmt.Errorf("%w: %s", ErrMissingExport, name)
}

func validateRouteResultV0(memorySize uint32, result routeResultViewV0) error {
	if err := validateRegion(memorySize, result.ETagPtr, result.ETagSize, "etag"); err != nil {
		return err
	}
	if err := validateRegion(memorySize, result.ContentTypePtr, result.ContentTypeSize, "content_type"); err != nil {
		return err
	}
	if err := validateDigestRegion(memorySize, result.ContentSHA256Ptr, result.ContentSHA256Count, "content_sha256"); err != nil {
		return err
	}
	if err := validateDigestRegion(memorySize, result.RecipeSHA256Ptr, result.RecipeSHA256Count, "recipe_sha256"); err != nil {
		return err
	}
	if err := validateRegion(memorySize, result.LocationPtr, result.LocationSize, "location"); err != nil {
		return err
	}
	if isRedirectStatus(result.Status) && result.LocationSize <= 0 {
		return fmt.Errorf("%w: status=%d location_size=%d", ErrInvalidRedirect, result.Status, result.LocationSize)
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

func validateRegion(memorySize uint32, ptr int32, size int32, field string) error {
	if size < 0 {
		return fmt.Errorf("%w: %s_size=%d", ErrOutOfBounds, field, size)
	}
	return validateRegionU64(memorySize, ptr, uint64(size), field)
}

func validateRegionU64(memorySize uint32, ptr int32, size uint64, field string) error {
	if ptr < 0 {
		return fmt.Errorf("%w: %s_ptr=%d", ErrOutOfBounds, field, ptr)
	}

	start := uint64(ptr)
	end := start + size
	if end < start {
		return fmt.Errorf("%w: %s ptr=%d size=%d", ErrOutOfBounds, field, ptr, size)
	}
	if end > uint64(memorySize) {
		return fmt.Errorf("%w: %s ptr=%d size=%d memory_size=%d", ErrOutOfBounds, field, ptr, size, memorySize)
	}
	return nil
}
