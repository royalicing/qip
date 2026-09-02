//! JPEG to canonical top-down RGBA8 sRGB KTX2 entrypoint.
//!
//! The decoder is a private JPEG library, not another Content component.

pub const JPEG_OUTPUT_KTX2 = true;
const decoder = @import("jpeg_decoder");

export fn input_ptr() u32 {
    return decoder.input_ptr();
}

export fn input_bytes_cap() u32 {
    return decoder.input_bytes_cap();
}

export fn output_bytes_cap() u32 {
    return decoder.output_bytes_cap();
}

export fn input_content_type_ptr() u32 {
    return decoder.input_content_type_ptr();
}

export fn input_content_type_size() u32 {
    return decoder.input_content_type_size();
}

export fn output_content_type_ptr() u32 {
    return decoder.output_content_type_ptr();
}

export fn output_content_type_size() u32 {
    return decoder.output_content_type_size();
}

export fn render(input_size_in: u32) decoder.RenderResult {
    return decoder.render(input_size_in);
}
