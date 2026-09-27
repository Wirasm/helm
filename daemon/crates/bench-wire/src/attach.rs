//! The viewer's half of an attach stream, after the response line.
//!
//! benchd writes the session's output down the stream as raw bytes, which is what lets an OSC
//! reach whatever terminal hosts `bench attach`. What the viewer sends up is framed, because it
//! carries two things: keystrokes for the pty, and the viewer's size. A size in the same stream
//! as the keys arrives in order with them and costs no connection of its own; a pane dragged
//! across the screen sends one per frame (#359's resize note).
//!
//! A frame is `[kind u8][len u32 big-endian][payload]`. Kind 0 is input bytes; kind 1 is a size,
//! rows then columns, each a `u16` big-endian. Anything else is a malformed stream, and the
//! reader says so rather than guessing where the next frame starts.

use std::io::{self, Read};

const INPUT: u8 = 0;
const SIZE: u8 = 1;

/// A frame's payload is at most this long. Input is sent as it is read, a few KiB at a time;
/// a longer length is a stream that is not speaking this protocol.
pub const MAX_FRAME: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachFrame {
    /// Bytes for the session's pty, exactly as the viewer's terminal produced them.
    Input(Vec<u8>),
    /// The viewer's terminal is now this size. A size of zero is not a size.
    Size { rows: u16, cols: u16 },
}

impl AttachFrame {
    pub fn encode(&self) -> Vec<u8> {
        let (kind, payload) = match self {
            AttachFrame::Input(bytes) => (INPUT, bytes.clone()),
            AttachFrame::Size { rows, cols } => {
                let mut p = rows.to_be_bytes().to_vec();
                p.extend_from_slice(&cols.to_be_bytes());
                (SIZE, p)
            }
        };
        let mut out = Vec::with_capacity(5 + payload.len());
        out.push(kind);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&payload);
        out
    }

    /// The next frame, `None` at a clean end of stream (between frames). A stream that ends
    /// inside a frame, names an unknown kind, or claims more than [`MAX_FRAME`] is an error.
    pub fn read(from: &mut impl Read) -> io::Result<Option<AttachFrame>> {
        let mut head = [0u8; 5];
        if from.read(&mut head[..1])? == 0 {
            return Ok(None);
        }
        // Judged before the length is read: a stream that is not framed at all (a client from
        // before framing, sending keys) is refused on its first byte, not left waiting for four.
        if head[0] != INPUT && head[0] != SIZE {
            return Err(malformed(format!(
                "frame kind {}, not 0 (input) or 1 (size)",
                head[0]
            )));
        }
        from.read_exact(&mut head[1..])?;
        let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
        if len > MAX_FRAME {
            return Err(malformed(format!(
                "a frame of {len} bytes, over {MAX_FRAME}"
            )));
        }
        let mut payload = vec![0u8; len];
        from.read_exact(&mut payload)?;
        match (head[0], payload.as_slice()) {
            (INPUT, _) => Ok(Some(AttachFrame::Input(payload))),
            (SIZE, &[r0, r1, c0, c1]) => {
                let (rows, cols) = (u16::from_be_bytes([r0, r1]), u16::from_be_bytes([c0, c1]));
                if rows == 0 || cols == 0 {
                    return Err(malformed(format!("a size of {rows}x{cols}")));
                }
                Ok(Some(AttachFrame::Size { rows, cols }))
            }
            _ => Err(malformed(format!("a size frame of {len} bytes, not 4"))),
        }
    }
}

fn malformed(what: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("attach stream: {what}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_back_to_back() {
        let sent = [
            AttachFrame::Input(b"ls\r".to_vec()),
            AttachFrame::Size { rows: 33, cols: 77 },
            AttachFrame::Input(vec![0x1c, 0x1b, b'[', b'A']),
            AttachFrame::Input(Vec::new()),
        ];
        let wire: Vec<u8> = sent.iter().flat_map(AttachFrame::encode).collect();
        let mut r = wire.as_slice();
        for want in &sent {
            assert_eq!(AttachFrame::read(&mut r).unwrap().as_ref(), Some(want));
        }
        assert_eq!(AttachFrame::read(&mut r).unwrap(), None, "a clean end");
    }

    #[test]
    fn a_malformed_stream_is_an_error_not_a_guess() {
        let refused = |bytes: &[u8]| AttachFrame::read(&mut &bytes[..]).unwrap_err().to_string();
        assert!(refused(&[7, 0, 0, 0, 0]).contains("kind 7"));
        assert!(refused(&[0, 0, 1, 0, 1]).contains("over"));
        assert!(refused(&[1, 0, 0, 0, 2, 0, 1]).contains("not 4"));
        assert!(refused(&[1, 0, 0, 0, 4, 0, 0, 0, 80]).contains("0x80"));
        // Ends inside a frame.
        assert!(AttachFrame::read(&mut &[0u8, 0, 0, 0, 3, b'a'][..]).is_err());
        // Unframed keys are refused on the first byte, before a length is waited for.
        assert!(refused(b"l").contains("kind 108"));
    }
}
