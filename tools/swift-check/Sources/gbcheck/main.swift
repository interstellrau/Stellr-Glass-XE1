// gbcheck - checks the iPhone Core (ios/GlassBridge/Core, copied in by run.sh) on any
// platform with Swift. Run tools/swift-check/run.sh rather than this directly.
//
//   gbcheck parse <stream.bin> <expected.json>   part 1: parse the Python stream
//   gbcheck fuzz <corpus.json> <results.json>    part 1: header verdicts for parser_fuzz.py
//   gbcheck reencode <stream.bin> <out.bin>      part 2: re-encode it (Python verifies)
//   gbcheck emit <out.bin>                       part 2: one frame per Msg builder
//                                                (check_messages.py validates them)
//   gbcheck nav                                  part 3: NavTracker on synthetic routes
//   gbcheck unit                                 part 4: classify, Wi-Fi QR, pairing, framing
//
// Exit status: 0 pass, 1 failure, 2 usage / unreadable input.

import Foundation

func usage() -> Int32 {
    print("usage: gbcheck parse <stream.bin> <expected.json> | fuzz <corpus.json> <results.json> | reencode <in.bin> <out.bin> | emit <out.bin> | nav | unit")
    return 2
}

let arguments: [String] = CommandLine.arguments
var status: Int32 = 2
if arguments.count >= 2 {
    switch arguments[1] {
    case "parse":
        status = arguments.count == 4 ? runParse(streamPath: arguments[2], expectedPath: arguments[3]) : usage()
    case "reencode":
        status = arguments.count == 4 ? runReencode(inPath: arguments[2], outPath: arguments[3]) : usage()
    case "fuzz":
        status = arguments.count == 4 ? runFuzz(corpusPath: arguments[2], resultsPath: arguments[3]) : usage()
    case "emit":
        status = arguments.count == 3 ? runEmit(outPath: arguments[2]) : usage()
    case "nav":
        status = runNav()
    case "unit":
        status = runUnit()
    default:
        status = usage()
    }
} else {
    status = usage()
}
exit(status)
