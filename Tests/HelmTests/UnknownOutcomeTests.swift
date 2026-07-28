import XCTest

@testable import Helm

/// A timed-out mutation is not a failure.
///
/// kild's own words, after building the timeout that makes this reachable: *"A client abort
/// does not reach the engine — nothing passes a signal server-side and no git command it
/// runs is cancellable — so a timed-out merge may well have landed."*
///
/// So the dangerous report is not "it broke", it is "it failed" — because the obvious
/// response to a failed land is to land again, and the merge may already have happened.
final class UnknownOutcomeTests: XCTestCase {
    private var client: KildHTTPClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = KildHTTPClient(urlSession: URLSession(configuration: config))
    }

    // MARK: - Mutations that cannot be repeated

    func testATimedOutLandReportsAnUnknownOutcome() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        do {
            _ = try await client.land("k-1")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? KildAPIError, .outcomeUnknown(verb: "land"))
        }
    }

    func testATimedOutDisposalReportsAnUnknownOutcome() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        do {
            _ = try await client.delete("k-1", force: false)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? KildAPIError, .outcomeUnknown(verb: "disposal"))
        }
    }

    /// The property that matters more than the label: nothing may offer a retry.
    func testAnUnknownOutcomeIsNeverSafeToRetry() {
        XCTAssertFalse(KildAPIError.outcomeUnknown(verb: "land").isSafeToRetry)
    }

    /// It must say what to do, not merely that something went wrong.
    func testTheMessageTellsYouToCheckFirst() {
        let message = KildAPIError.outcomeUnknown(verb: "land").errorDescription ?? ""
        XCTAssertTrue(message.contains("may have completed"))
        XCTAssertTrue(message.contains("check before retrying"))
    }

    // MARK: - Everything else stays a plain failure

    /// A READ that times out changed nothing, so repeating it is free.
    func testATimedOutReadIsAPlainFailureAndIsRetryable() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        do {
            _ = try await client.kilds()
            XCTFail("must throw")
        } catch {
            guard case .unreachable = error as? KildAPIError else {
                return XCTFail("a read must not claim an unknown outcome, got \(error)")
            }
            XCTAssertTrue((error as! KildAPIError).isSafeToRetry)
        }
    }

    /// A refused connection is not a timeout: the request never reached the engine, so even
    /// a mutation certainly did not happen. Conflating the two would make every engine
    /// restart look like a possibly-completed merge.
    func testARefusedConnectionIsUnreachableEvenForAMutation() async {
        StubURLProtocol.fail(with: URLError(.cannotConnectToHost))
        do {
            _ = try await client.land("k-1")
            XCTFail("must throw")
        } catch {
            guard case .unreachable = error as? KildAPIError else {
                return XCTFail("nothing was sent; this is not unknown, got \(error)")
            }
        }
    }

    /// An engine REFUSAL is still a refusal — the timeout handling must not swallow the
    /// engine's own reasoning.
    func testAnEngineRefusalIsUnaffected() async {
        StubURLProtocol.respond(status: 409, json: #"{"error":"refusing: unlanded work"}"#)
        do {
            _ = try await client.delete("k-1", force: false)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? KildAPIError, .engine("refusing: unlanded work"))
        }
    }

    /// Transport failures used to leak raw URLError to callers, so a timeout was
    /// indistinguishable from a refusal at the call site.
    func testTransportFailuresNeverLeakRawURLErrors() async {
        StubURLProtocol.fail(with: URLError(.networkConnectionLost))
        do {
            _ = try await client.kilds()
            XCTFail("must throw")
        } catch {
            XCTAssertNotNil(error as? KildAPIError, "must be wrapped, not a raw URLError")
        }
    }
}
