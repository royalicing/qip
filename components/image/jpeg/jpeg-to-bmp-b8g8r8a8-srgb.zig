//! JPEG to BMP entrypoint. The decoder lives in the private JPEG library so
//! BMP and KTX2 outputs share one parser and pixel conversion path.

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
