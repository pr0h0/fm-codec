# WebAssembly entry: the module exports everything (wasm-ld --export-all); hosts call
# fm3InputBuffer / fm3Encode / fm3Decode / fm3Result / fm3Estimate directly. main is unused.
import fm3Encode, fm3Decode, fm3Result, fm3InputBuffer, fm3Estimate from "./fm3_core.bpl";

frame main() ret int {
    return 0;
}
