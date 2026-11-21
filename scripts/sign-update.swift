import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let secret = ProcessInfo.processInfo.environment["HUSK_UPDATE_SIGNING_KEY"]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
      let keyBytes = Data(base64Encoded: secret) else {
    FileHandle.standardError.write(Data("A valid HUSK_UPDATE_SIGNING_KEY is required.\n".utf8))
    exit(1)
}

let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[2] else {
    FileHandle.standardError.write(Data("The signing key does not match the public key in Husk.\n".utf8))
    exit(1)
}

let archive = URL(fileURLWithPath: arguments[1])
let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
let signature = try key.signature(for: bytes).base64EncodedString()
try (signature + "\n").write(to: archive.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
