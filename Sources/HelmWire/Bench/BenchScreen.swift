import Foundation

/// `screen/get` and `screen/send` as Pocket sends them (#625): read a session's screen, and type
/// into it as the operator. Pinned against `daemon/fixtures/screen-verbs.json`, which the daemon
/// gate reads into `bench_wire::ScreenGetArgs` and `ScreenSendArgs`.
///
/// A target is a session id or the id of the pane showing it, as benchd takes either.
package enum BenchScreenRequest: Encodable, Equatable, Sendable {
    case get(id: String, target: String)
    case send(id: String, target: String, input: BenchScreenInput)

    private enum CodingKeys: String, CodingKey { case id, verb, args, by }
    private enum ArgKeys: String, CodingKey { case target, text, enter, keys }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        switch self {
        case let .get(id, target):
            try c.encode(id, forKey: .id)
            try c.encode("screen/get", forKey: .verb)
            try args.encode(target, forKey: .target)
        case let .send(id, target, input):
            try c.encode(id, forKey: .id)
            try c.encode("screen/send", forKey: .verb)
            // The operator typed it; benchd only records who for a send.
            try c.encode(BenchActor.operatorGesture, forKey: .by)
            try args.encode(target, forKey: .target)
            switch input {
            case let .keys(bytes):
                try args.encode(bytes, forKey: .text)
                try args.encode(true, forKey: .keys)
            case let .message(text):
                try args.encode(text, forKey: .text)
                try args.encode(true, forKey: .enter)
            }
        }
    }
}

/// What the operator types into a session.
package enum BenchScreenInput: Equatable, Sendable {
    /// Keys, written as they are (`keys: true`): Esc, Ctrl-C, an arrow, a digit picking an
    /// option. Inside a bracketed paste a program would read them as text.
    case keys(String)
    /// A message: pasted as one piece, then Return on its own.
    case message(String)
}

/// `screen/get`'s answer (`bench_wire::ScreenAnswer`), reduced to what Pocket draws.
package struct BenchScreen: Decodable, Equatable, Sendable {
    /// One string per row, trailing blanks trimmed.
    package var lines: [String]
}

/// `screen/send`'s answer. Pocket reads only that it was ok.
package struct BenchScreenSent: Decodable, Equatable, Sendable {}
