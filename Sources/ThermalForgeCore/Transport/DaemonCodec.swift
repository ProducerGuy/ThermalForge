import Foundation

public enum DaemonCodec {
    public static func encodeRequest(_ request: DaemonRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> DaemonRequest {
        try JSONDecoder().decode(DaemonRequest.self, from: data)
    }

    public static func encodeResponse(_ response: DaemonResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> DaemonResponse {
        try JSONDecoder().decode(DaemonResponse.self, from: data)
    }
}
