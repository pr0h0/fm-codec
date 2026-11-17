# WebAssembly entry: the module exports everything (wasm-ld --export-all); hosts call
# fm4InputBuffer / fm4Encode / fm4Decode / fm4Result / fm4Estimate directly. main is unused.
import fm4Encode, fm4Decode, fm4Result, fm4InputBuffer, fm4Estimate from "./fm4_core.bpl";

frame main() ret int {
    return 0;
}
