import Foundation

extension CodexCostProvider {
    func parseSessionMetadata(_ path: String) -> SessionMetadata? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var buffer = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                if let metadata = parseSessionMetadataLine(lineData) {
                    return metadata
                }
            }
        }
        return parseSessionMetadataLine(buffer)
    }

    func parseSessionMetadataLine(_ data: Data) -> SessionMetadata? {
        guard !data.isEmpty,
              data.range(of: Self.sessionMetaNeedle) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta" else {
            return nil
        }
        let payload = obj["payload"] as? [String: Any]
        return SessionMetadata(
            sessionId: firstNonEmpty(
                payload?["session_id"] as? String,
                payload?["sessionId"] as? String,
                payload?["id"] as? String,
                obj["session_id"] as? String,
                obj["sessionId"] as? String,
                obj["id"] as? String
            ),
            forkedFromId: firstNonEmpty(
                payload?["forked_from_id"] as? String,
                payload?["forkedFromId"] as? String,
                payload?["parent_session_id"] as? String,
                payload?["parentSessionId"] as? String
            ),
            forkTimestamp: firstNonEmpty(payload?["timestamp"] as? String, obj["timestamp"] as? String),
            modelProvider: firstNonEmpty(
                payload?["model_provider"] as? String,
                payload?["modelProvider"] as? String
            )
        )
    }

    func parseTokenSnapshots(_ path: String) -> (sessionId: String?, snapshots: [TimestampedTotals]) {
        var sessionId: String?
        var previousTotals: CodexTotals?
        var snapshots: [TimestampedTotals] = []

        scanJSONLLines(
            path,
            matching: [Self.sessionMetaNeedle, Self.tokenCountNeedle],
            maxLineBytes: 512 * 1024,
            prefixBytes: 512 * 1024
        ) { data in
            if data.range(of: Self.sessionMetaNeedle) != nil {
                if sessionId == nil {
                    sessionId = parseSessionMetadataLine(data)?.sessionId
                }
                return
            }

            guard data.range(of: Self.compactEventMsgTypeNeedle) != nil,
                  data.range(of: Self.tokenCountNeedle) != nil,
                  let timestamp = extractJSONStringField("timestamp", from: data) else {
                return
            }

            if let next = tokenUsageTotals(named: "total_token_usage", in: data) {
                previousTotals = next
                snapshots.append(TimestampedTotals(timestamp: timestamp, date: parseTimestamp(timestamp), totals: next))
            } else if let last = tokenUsageTotals(named: "last_token_usage", in: data) {
                let base = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                let next = CodexTotals(
                    input: base.input + last.input,
                    cached: base.cached + last.cached,
                    output: base.output + last.output
                )
                previousTotals = next
                snapshots.append(TimestampedTotals(timestamp: timestamp, date: parseTimestamp(timestamp), totals: next))
            }
        }

        return (sessionId, snapshots)
    }

}
