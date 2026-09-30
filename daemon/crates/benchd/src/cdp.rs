//! `browser/connect`: a view onto the shared browser, relayed (M5c, #459).
//!
//! helm's browser pane used to read `<root>/browser/endpoint.json` and open the browser's
//! websocket itself, which only works on the machine the browser runs on. Now benchd opens that
//! websocket and the pane's own connection to benchd carries the messages: after the response
//! line, each line the pane writes goes to the browser as one text message, and each message the
//! browser sends goes to the pane as one line (`bench_wire::BrowserConnected`). A CDP message is
//! a JSON object, and JSON holds a raw newline only as whitespace between tokens, so a newline in
//! a message from the browser becomes a space and the message means the same.
//!
//! The websocket half is the least a client of the browser's own debugging server needs
//! (RFC 6455): the upgrade, masked frames out, 7/16/64-bit lengths, continuation, ping and
//! close. benchd still never drives the browser; it carries what the pane says.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A message larger than this from either side ends the relay. A screencast frame of a large
/// retina pane is a few MB of base64; this is far above that and far below running out.
const MESSAGE_MAX_BYTES: usize = 64 * 1024 * 1024;

const OP_CONTINUATION: u8 = 0x0;
const OP_TEXT: u8 = 0x1;
const OP_BINARY: u8 = 0x2;
const OP_CLOSE: u8 = 0x8;
const OP_PING: u8 = 0x9;
const OP_PONG: u8 = 0xA;

/// Open the browser-level websocket `ws` (`ws://host:port/path`, the endpoint benchd holds).
pub fn open(ws: &str) -> Result<TcpStream, String> {
    let rest = ws
        .strip_prefix("ws://")
        .ok_or_else(|| format!("the browser's endpoint {ws} is not a ws:// address"))?;
    let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let path = if path.is_empty() { "/" } else { path };
    let address = authority
        .to_socket_addrs()
        .ok()
        .and_then(|mut all| all.next())
        .ok_or_else(|| format!("cannot resolve the browser's address {authority}"))?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(5))
        .map_err(|e| format!("cannot reach the browser at {authority}: {e}"))?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {authority}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
         Sec-WebSocket-Key: {}\r\nSec-WebSocket-Version: 13\r\n\r\n",
        bench_wire::base64(&mask_key().repeat(4)),
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("cannot write to the browser: {e}"))?;
    let head = read_head(&mut stream).map_err(|e| format!("the browser did not answer: {e}"))?;
    let status = head.lines().next().unwrap_or_default();
    if !status.contains(" 101 ") {
        return Err(format!("the browser refused the websocket: {status}"));
    }
    let _ = stream.set_read_timeout(None);
    Ok(stream)
}

/// The HTTP response head, read a byte at a time so nothing after it is taken from the stream.
fn read_head(stream: &mut TcpStream) -> io::Result<String> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 16 * 1024 {
            return Err(io::Error::other("a response head over 16 KB"));
        }
        stream.read_exact(&mut byte)?;
        head.push(byte[0]);
    }
    Ok(String::from_utf8_lossy(&head).into_owned())
}

/// A masking key. The mask exists so a browser cannot be fed bytes a proxy would read as
/// HTTP; nothing sits between benchd and a browser on the same machine, so varying it is
/// enough and it need not be secret.
fn mask_key() -> [u8; 4] {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    (nanos ^ 0x9E37_79B9).to_le_bytes()
}

/// One frame, from benchd to the browser: always masked, always final.
fn write_frame(out: &mut impl Write, opcode: u8, payload: &[u8], mask: [u8; 4]) -> io::Result<()> {
    let mut frame = Vec::with_capacity(payload.len() + 14);
    frame.push(0x80 | opcode);
    match payload.len() {
        n if n < 126 => frame.push(0x80 | n as u8),
        n if n <= 0xFFFF => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    frame.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out.write_all(&frame)
}

struct Frame {
    fin: bool,
    opcode: u8,
    payload: Vec<u8>,
}

fn read_frame(input: &mut impl Read) -> io::Result<Frame> {
    let mut head = [0u8; 2];
    input.read_exact(&mut head)?;
    let len = match head[1] & 0x7F {
        126 => {
            let mut n = [0u8; 2];
            input.read_exact(&mut n)?;
            u64::from(u16::from_be_bytes(n))
        }
        127 => {
            let mut n = [0u8; 8];
            input.read_exact(&mut n)?;
            u64::from_be_bytes(n)
        }
        n => u64::from(n),
    };
    if len > MESSAGE_MAX_BYTES as u64 {
        return Err(io::Error::other(format!("a {len}-byte frame")));
    }
    let mask = if head[1] & 0x80 != 0 {
        let mut m = [0u8; 4];
        input.read_exact(&mut m)?;
        Some(m)
    } else {
        None
    };
    let mut payload = vec![0u8; len as usize];
    input.read_exact(&mut payload)?;
    if let Some(m) = mask {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= m[i % 4];
        }
    }
    Ok(Frame {
        fin: head[0] & 0x80 != 0,
        opcode: head[0] & 0x0F,
        payload,
    })
}

/// The next whole data message, answering pings on the way through `pong`. `None` is the
/// browser closing the socket.
fn read_message(
    input: &mut impl Read,
    mut pong: impl FnMut(&[u8]) -> io::Result<()>,
) -> io::Result<Option<Vec<u8>>> {
    let mut message: Option<Vec<u8>> = None;
    loop {
        let frame = read_frame(input)?;
        match frame.opcode {
            OP_CLOSE => return Ok(None),
            OP_PING => pong(&frame.payload)?,
            OP_PONG => {}
            OP_TEXT | OP_BINARY | OP_CONTINUATION => {
                let whole = message.get_or_insert_with(Vec::new);
                if whole.len() + frame.payload.len() > MESSAGE_MAX_BYTES {
                    return Err(io::Error::other("a message over 64 MB"));
                }
                whole.extend_from_slice(&frame.payload);
                if frame.fin {
                    return Ok(message);
                }
            }
            other => return Err(io::Error::other(format!("websocket opcode {other}"))),
        }
    }
}

/// Carry messages between the pane (`viewer`, past its response line) and the browser until
/// either side ends, and say which did.
pub fn relay(viewer: &UnixStream, mut input: BufReader<UnixStream>, browser: TcpStream) -> String {
    let _ = viewer.set_read_timeout(None);
    let (Ok(to_viewer), Ok(from_browser), Ok(browser_writer)) =
        (viewer.try_clone(), browser.try_clone(), browser.try_clone())
    else {
        return "could not share the connections between threads".into();
    };
    let writer = Arc::new(Mutex::new(browser_writer));
    // Whichever side ends first is the reason; the other only follows it down.
    let first: Arc<Mutex<Option<String>>> = Arc::default();

    let pongs = Arc::clone(&writer);
    let ended = Arc::clone(&first);
    let down = std::thread::spawn(move || {
        let mut input = BufReader::with_capacity(256 * 1024, from_browser);
        let mut out = &to_viewer;
        let why = loop {
            let pong = |payload: &[u8]| {
                write_frame(&mut *pongs.lock().unwrap(), OP_PONG, payload, mask_key())
            };
            match read_message(&mut input, pong) {
                Ok(Some(mut message)) => {
                    for b in &mut message {
                        if *b == b'\n' {
                            *b = b' ';
                        }
                    }
                    message.push(b'\n');
                    if let Err(e) = out.write_all(&message) {
                        break format!("the viewer stopped reading: {e}");
                    }
                }
                Ok(None) => break "the browser closed the connection".to_string(),
                Err(e) => break format!("the browser connection failed: {e}"),
            }
        };
        ended.lock().unwrap().get_or_insert(why);
        let _ = to_viewer.shutdown(Shutdown::Both);
        let _ = pongs.lock().unwrap().shutdown(Shutdown::Both);
    });

    let mut line = Vec::new();
    let up = loop {
        line.clear();
        match (&mut input)
            .take(MESSAGE_MAX_BYTES as u64 + 1)
            .read_until(b'\n', &mut line)
        {
            Ok(0) => break "the viewer left".to_string(),
            Ok(_) if line.len() > MESSAGE_MAX_BYTES => {
                break "the viewer sent a message over 64 MB".to_string();
            }
            Ok(_) => {}
            Err(e) => break format!("the viewer connection failed: {e}"),
        }
        let message = line.strip_suffix(b"\n").unwrap_or(&line);
        if message.is_empty() {
            continue;
        }
        if let Err(e) = write_frame(&mut *writer.lock().unwrap(), OP_TEXT, message, mask_key()) {
            break format!("could not write to the browser: {e}");
        }
    };
    first.lock().unwrap().get_or_insert(up);
    {
        let mut browser = writer.lock().unwrap();
        let _ = write_frame(&mut *browser, OP_CLOSE, &[], mask_key());
        let _ = browser.shutdown(Shutdown::Both);
    }
    let _ = viewer.shutdown(Shutdown::Both);
    let _ = down.join();
    first
        .lock()
        .unwrap()
        .take()
        .unwrap_or_else(|| "the relay ended".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frame as a server sends it: unmasked.
    fn server_frame(fin: bool, opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mut f = vec![if fin { 0x80 } else { 0 } | opcode];
        match payload.len() {
            n if n < 126 => f.push(n as u8),
            n if n <= 0xFFFF => {
                f.push(126);
                f.extend_from_slice(&(n as u16).to_be_bytes());
            }
            n => {
                f.push(127);
                f.extend_from_slice(&(n as u64).to_be_bytes());
            }
        }
        f.extend_from_slice(payload);
        f
    }

    #[test]
    fn a_frame_out_is_masked_and_carries_each_length_form() {
        for len in [0usize, 125, 126, 65535, 65536] {
            let payload = vec![b'x'; len];
            let mut out = Vec::new();
            write_frame(&mut out, OP_TEXT, &payload, [1, 2, 3, 4]).unwrap();
            assert_eq!(out[0], 0x81, "final text frame");
            assert_ne!(out[1] & 0x80, 0, "a client's frame is masked");
            let back = read_frame(&mut out.as_slice()).unwrap();
            assert_eq!(back.payload, payload, "length {len}");
            assert!(back.fin);
            let header = match len {
                n if n < 126 => 2,
                n if n <= 0xFFFF => 4,
                _ => 10,
            };
            assert_eq!(out.len(), header + 4 + len);
        }
    }

    #[test]
    fn a_message_in_fragments_arrives_whole_and_a_ping_is_answered_on_the_way() {
        let mut bytes = server_frame(false, OP_TEXT, b"{\"id\":");
        bytes.extend(server_frame(true, OP_PING, b"hi"));
        bytes.extend(server_frame(true, OP_CONTINUATION, b"1}"));
        bytes.extend(server_frame(true, OP_CLOSE, &[]));
        let mut input = bytes.as_slice();
        let mut pongs = Vec::new();
        let first = read_message(&mut input, |p| {
            pongs.push(p.to_vec());
            Ok(())
        })
        .unwrap();
        assert_eq!(first.as_deref(), Some(&b"{\"id\":1}"[..]));
        assert_eq!(pongs, vec![b"hi".to_vec()]);
        assert_eq!(read_message(&mut input, |_| Ok(())).unwrap(), None);
    }

    #[test]
    fn a_long_message_uses_the_64_bit_length() {
        let payload = vec![b'a'; 70_000];
        let bytes = server_frame(true, OP_TEXT, &payload);
        assert_eq!(bytes[1], 127);
        let got = read_message(&mut bytes.as_slice(), |_| Ok(())).unwrap();
        assert_eq!(got.map(|m| m.len()), Some(70_000));
    }

    #[test]
    fn an_endpoint_that_is_not_ws_is_refused_by_name() {
        let err = open("http://127.0.0.1:1/devtools").unwrap_err();
        assert!(err.contains("not a ws:// address"), "{err}");
    }
}
