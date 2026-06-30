import Foundation

extension Array {
    /// Split into consecutive sub-arrays of at most `size` elements (the last may
    /// be shorter). Used to lay metric tiles out in rows.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
