# WebAssembly entry: the module exports everything (wasm-ld --export-all); hosts call
# fm2InputBuffer / fm2Encode / fm2Decode / fm2Result / fm2Estimate directly. main is unused.
import fm2Encode, fm2Decode, fm2Result, fm2InputBuffer, fm2Estimate from "./fm2_core.bpl";

frame main() ret int {
    return 0;
}
