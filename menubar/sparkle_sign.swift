// EdDSA-sign a file for Sparkle's appcast (sparkle:edSignature) using the
// Ed25519 private key — no Sparkle CLI tools required.
//   swift sparkle_sign.swift <file> <ed25519-key-file>
// Prints: "<base64 signature> <byte length>"
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: sparkle_sign <file> <keyfile>\n".utf8))
    exit(2)
}
let file = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let keyB64 = (try String(contentsOfFile: args[2], encoding: .utf8))
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: keyB64) else {
    FileHandle.standardError.write(Data("key file is not valid base64\n".utf8)); exit(3)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData.prefix(32))
let sig = try key.signature(for: file)
print("\(sig.base64EncodedString()) \(file.count)")
