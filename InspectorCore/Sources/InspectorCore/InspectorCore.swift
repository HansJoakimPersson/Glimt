import Foundation

/// Failure categories for the small bounded UTF-8 file-reading convenience API.
public enum InspectorCoreError: Error, Equatable {
    case fileTooLarge(limit: Int)
    case invalidUTF8
    case readFailed(String)
}

/// Minimal public file-reading entry point for callers that only need bounded UTF-8 text.
public enum InspectorCore {
    /// Reads UTF-8 text up to an explicit byte ceiling. The extra byte distinguishes an exact-size
    /// input from a larger file without reading the rest of it.
    public static func readUTF8Text(from url: URL, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0 else {
            throw InspectorCoreError.fileTooLarge(limit: maximumBytes)
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var contents = Data()
            let chunkSize = 64 * 1024

            while true {
                let remaining = maximumBytes - contents.count
                // Read one byte beyond the remaining allowance to detect overflow deterministically.
                let bytesToRead = remaining >= chunkSize ? chunkSize : remaining + 1
                guard let chunk = try handle.read(upToCount: bytesToRead), !chunk.isEmpty else {
                    break
                }
                contents.append(chunk)

                if contents.count > maximumBytes {
                    throw InspectorCoreError.fileTooLarge(limit: maximumBytes)
                }
            }

            guard let text = String(data: contents, encoding: .utf8) else {
                throw InspectorCoreError.invalidUTF8
            }
            return text
        } catch let error as InspectorCoreError {
            throw error
        } catch {
            throw InspectorCoreError.readFailed(String(describing: error))
        }
    }
}
