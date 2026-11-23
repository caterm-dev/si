use std::net::{Ipv4Addr, Ipv6Addr};

pub(super) struct AddressSpan {
    pub(super) consumed_bytes: usize,
    pub(super) host_end: usize,
    pub(super) user_info_bytes: usize,
}

/// Find the entire address to consume and the scheme and host to learn.
pub(super) fn web_prefix(text: &str) -> Option<AddressSpan> {
    let scheme = ["https://", "http://"]
        .into_iter()
        .find(|scheme| {
            text.get(..scheme.len())
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case(scheme))
        })
        .map_or(0, str::len);
    let user_info = if scheme == 0 {
        0
    } else {
        user_info_len(&text[scheme..])
    };
    let address = &text[scheme + user_info..];
    let host = host_len(address, scheme != 0)?;
    let rest = &address[host..];
    if rest.starts_with('@') {
        return None;
    }
    let rest = rest
        .strip_prefix('.')
        .filter(|after_dot| after_dot.starts_with([':', '/', '?', '#']))
        .unwrap_or(rest);
    let port = rest.strip_prefix(':').map_or(0, |rest| {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits != 0
            && !rest
                .as_bytes()
                .get(digits)
                .is_some_and(u8::is_ascii_alphanumeric)
        {
            digits + 1
        } else {
            0
        }
    });
    let tail = &rest[port..];
    let tail_end = if tail.starts_with(['/', '?', '#']) {
        tail_len(tail)
    } else {
        0
    };
    // Leave terminal prose punctuation to the sentence segmenter.
    let suffix = tail[..tail_end].trim_end_matches(['.', ',', ';', ':', '!', '?', '\'']);
    Some(AddressSpan {
        consumed_bytes: text.len() - tail.len() + suffix.len(),
        host_end: scheme + user_info + host,
        user_info_bytes: user_info,
    })
}

/// Recognize an unquoted email address without consuming surrounding prose punctuation.
pub(super) fn email_prefix_len(text: &str, preceding: Option<u8>) -> Option<usize> {
    fn local_byte(byte: u8) -> bool {
        byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'%' | b'+' | b'-')
    }
    if preceding.is_some_and(|byte| local_byte(byte) || byte == b'@') {
        return None;
    }
    let end = text
        .bytes()
        .take(65)
        .take_while(|&byte| local_byte(byte))
        .count();
    let domain = text[end..].strip_prefix('@')?;
    if end > 64 || text[..end].split('.').any(str::is_empty) {
        return None;
    }
    let host = host_len(domain, false)?;
    let length = end + 1 + host;
    (length <= 254 && !domain[host..].starts_with(['@', '_', '%', '+'])).then_some(length)
}

fn user_info_len(address: &str) -> usize {
    let end = address
        .bytes()
        .take_while(|&byte| {
            byte.is_ascii_alphanumeric()
                || matches!(
                    byte,
                    b'-' | b'.'
                        | b'_'
                        | b'~'
                        | b'%'
                        | b':'
                        | b'!'
                        | b'$'
                        | b'&'
                        | b'\''
                        | b'('
                        | b')'
                        | b'*'
                        | b'+'
                        | b','
                        | b';'
                        | b'='
                )
        })
        .count();
    if address.as_bytes().get(end) == Some(&b'@') {
        end + 1
    } else {
        0
    }
}

fn host_len(address: &str, explicit_scheme: bool) -> Option<usize> {
    if explicit_scheme && let Some(literal) = address.strip_prefix('[') {
        let end = literal.bytes().take(46).position(|byte| byte == b']')?;
        return literal[..end].parse::<Ipv6Addr>().ok().map(|_| end + 2);
    }
    let mut length = 0;
    for character in address.chars().take_while(|&character| {
        character.is_ascii_alphanumeric()
            || matches!(character, '.' | '-')
            || (explicit_scheme && character.is_alphanumeric())
    }) {
        length += character.len_utf8();
        if length > 254 {
            return None;
        }
    }
    let host = address[..length].trim_end_matches('.');
    if host.is_empty() || host.len() > 253 {
        return None;
    }
    if host.parse::<Ipv4Addr>().is_ok() {
        return Some(host.len());
    }
    if !host.split('.').all(|label| {
        (1..=63).contains(&label.len()) && !label.starts_with('-') && !label.ends_with('-')
    }) {
        return None;
    }
    let domain = host.rsplit_once('.').is_some_and(|(_, top)| {
        (top.len() >= 2 && top.bytes().all(|byte| byte.is_ascii_alphabetic()))
            || (top.len() > 4 && top.as_bytes()[..4].eq_ignore_ascii_case(b"xn--"))
    });
    (explicit_scheme || domain).then_some(host.len())
}

fn tail_len(tail: &str) -> usize {
    let mut parens = 0;
    let mut brackets = 0;
    for (index, character) in tail.char_indices() {
        match character {
            '(' => parens += 1,
            '[' => brackets += 1,
            ')' if parens > 0 => parens -= 1,
            ']' if brackets > 0 => brackets -= 1,
            '/' | '?' | '#' | ':' | '@' | '!' | '$' | '&' | '\'' | '*' | '+' | ',' | ';' | '='
            | '-' | '.' | '_' | '~' | '%' => {}
            character if character.is_ascii_alphanumeric() || is_unicode_url_text(character) => {}
            _ => return index,
        }
    }
    tail.len()
}

fn is_unicode_url_text(character: char) -> bool {
    !character.is_ascii()
        && !character.is_whitespace()
        && !character.is_control()
        && !matches!(
            character,
            '。' | '，'
                | '、'
                | '！'
                | '？'
                | '；'
                | '：'
                | '…'
                | '”'
                | '’'
                | '」'
                | '』'
                | '）'
                | '】'
                | '》'
        )
}

#[cfg(test)]
mod tests {
    use super::{email_prefix_len, web_prefix};

    #[test]
    fn identifies_domains_and_consumes_the_rest_of_each_address() {
        for (text, consumed, domain) in [
            (
                "HTTPS://example.test./path?key=Value",
                "HTTPS://example.test./path?key=Value",
                "HTTPS://example.test",
            ),
            (
                "http://[::1]:8080/path",
                "http://[::1]:8080/path",
                "http://[::1]",
            ),
            ("127.0.0.1:8080/path", "127.0.0.1:8080/path", "127.0.0.1"),
            (
                "www.example.test/路径?q=One#章节，后文",
                "www.example.test/路径?q=One#章节",
                "www.example.test",
            ),
            (
                "https://示例.测试/📄",
                "https://示例.测试/📄",
                "https://示例.测试",
            ),
            (
                "example.test/path_(name)).",
                "example.test/path_(name)",
                "example.test",
            ),
            (
                "example.test/path?q=One!, after",
                "example.test/path?q=One",
                "example.test",
            ),
            ("example.test. after", "example.test", "example.test"),
        ] {
            let span = web_prefix(text).unwrap();
            assert_eq!(&text[..span.consumed_bytes], consumed);
            assert_eq!(&text[..span.host_end], domain);
            assert_eq!(span.user_info_bytes, 0);
        }
    }

    #[test]
    fn locates_user_info_before_the_host() {
        let text = "https://user:Password@example.test:8080/private?q=token";
        let span = web_prefix(text).unwrap();
        assert_eq!(span.consumed_bytes, text.len());
        assert_eq!(
            &text["https://".len() + span.user_info_bytes..span.host_end],
            "example.test"
        );
    }

    #[test]
    fn skips_prose_numbers_email_addresses_and_invalid_hosts_in_web_matching() {
        for text in [
            "alpha beta",
            "3.14",
            "name.surname@example.test",
            "https://",
            "https://[bad]",
        ] {
            assert!(web_prefix(text).is_none(), "{text}");
        }
    }

    #[test]
    fn returns_the_complete_email_address_before_prose_punctuation() {
        for (text, expected) in [
            ("Sample89@example.test.", "Sample89@example.test"),
            (
                "_Reader.Name+news@team.example.test，继续",
                "_Reader.Name+news@team.example.test",
            ),
        ] {
            let length = email_prefix_len(text, Some(b'(')).unwrap();
            assert_eq!(&text[..length], expected);
        }
    }

    #[test]
    fn rejects_partial_or_malformed_email_addresses() {
        for text in [
            "@example.test",
            ".reader@example.test",
            "reader..name@example.test",
            "reader.@example.test",
            "reader@example",
            "reader@example.test@elsewhere.test",
            "reader@example.test_tag",
        ] {
            assert_eq!(email_prefix_len(text, None), None, "{text}");
        }
        assert_eq!(email_prefix_len("reader@example.test", Some(b'@')), None);
    }
}
