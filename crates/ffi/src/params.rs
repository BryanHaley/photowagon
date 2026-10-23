//! Settings a command takes, read from its params doc (`{"radius":0.1..1000=1,"mode":"a|b"}`), so
//! the app can ask for them before running it. Params the doc spells another way (paths, ids,
//! JSON) are left out and keep the engine's defaults.

#[derive(uniffi::Enum, Debug, PartialEq)]
pub enum FieldKind {
    Number { min: Option<f64>, max: Option<f64>, value: f64, whole: bool },
    Choice { options: Vec<String>, value: String },
    Toggle { value: bool },
    Text { value: String },
    /// A colour (`#rrggbb`), or one of `options` (`background`, `foreground`…). An empty `value`
    /// leaves the engine's default until one is picked.
    Color { options: Vec<String>, value: String },
}

#[derive(uniffi::Record, Debug, PartialEq)]
pub struct ParamField {
    pub name: String,
    pub kind: FieldKind,
}

pub fn fields(doc: &str) -> Vec<ParamField> {
    first_object(doc).map(|body| split_top(body).into_iter().filter_map(field).collect()).unwrap_or_default()
}

/// The inside of the first `{…}`.
fn first_object(s: &str) -> Option<&str> {
    let start = s.find('{')?;
    let mut depth = 0i32;
    let mut quoted = false;
    for (i, c) in s.char_indices().skip_while(|(i, _)| *i < start) {
        match c {
            '"' => quoted = !quoted,
            '{' | '[' | '(' if !quoted => depth += 1,
            '}' | ']' | ')' if !quoted => {
                depth -= 1;
                if depth == 0 {
                    return s.get(start + 1..i);
                }
            }
            _ => {}
        }
    }
    None
}

/// `s` split at the commas outside brackets and quotes.
fn split_top(s: &str) -> Vec<&str> {
    let (mut out, mut depth, mut quoted, mut from) = (Vec::new(), 0i32, false, 0);
    for (i, c) in s.char_indices() {
        match c {
            '"' => quoted = !quoted,
            '{' | '[' | '(' if !quoted => depth += 1,
            '}' | ']' | ')' if !quoted => depth -= 1,
            ',' if !quoted && depth == 0 => {
                out.extend(s.get(from..i));
                from = i + 1;
            }
            _ => {}
        }
    }
    out.extend(s.get(from..));
    out
}

fn field(item: &str) -> Option<ParamField> {
    let (name, rest) = item.trim().strip_prefix('"')?.split_once('"')?;
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    let v = rest.trim_start().strip_prefix(':')?.trim_start();
    let kind = if let Some(r) = v.strip_prefix("bool") {
        FieldKind::Toggle { value: r.starts_with("=true") }
    } else if v.starts_with("str") || v.starts_with("text") {
        let value = v.split_once("=\"").and_then(|(_, d)| d.split_once('"')).map_or_else(String::new, |(d, _)| d.to_string());
        FieldKind::Text { value }
    } else if v.starts_with("color") {
        FieldKind::Color { options: Vec::new(), value: String::new() }
    } else if let Some(r) = v.strip_prefix('"') {
        let (list, after) = r.split_once('"')?;
        if list.split('|').any(|o| o == "#rrggbb") {
            let options: Vec<String> = list.split('|').filter(|o| is_word(o)).map(String::from).collect();
            let given = after.strip_prefix("=\"").and_then(|d| d.split_once('"')).map(|(d, _)| d);
            let value = given.filter(|d| options.iter().any(|o| o == d)).map_or_else(String::new, String::from);
            return Some(ParamField { name: name.into(), kind: FieldKind::Color { options, value } });
        }
        let options: Vec<String> = list.split('|').filter(|o| is_word(o)).map(String::from).collect();
        if options.len() < 2 {
            return None;
        }
        let given = after.strip_prefix("=\"").and_then(|d| d.split_once('"')).map(|(d, _)| d);
        let value = given.filter(|d| options.iter().any(|o| o == d)).map_or_else(|| options[0].clone(), String::from);
        FieldKind::Choice { options, value }
    } else if let Some((min, r)) = number(v)
        && let Some(r) = r.strip_prefix("..")
    {
        let (max, r) = number(r)?;
        let given = r.strip_prefix('=').and_then(number);
        let value = given.map_or(0.0_f64.clamp(min.min(max), max.max(min)), |(d, _)| d);
        // `0..1` is a fraction.
        let whole = [min, max, value].iter().all(|n| n.fract() == 0.0) && max - min > 1.0;
        FieldKind::Number { min: Some(min), max: Some(max), value, whole }
    } else {
        // A unit then a default: `px=0`, `deg=90`, `%=100`. `=current` (the document's own value)
        // starts at 0 and the app fills it in.
        let (_, d) = v.split_once('=').filter(|(unit, _)| ["px", "deg", "%", "n", "mm", "ppi"].contains(unit))?;
        let value = if d.starts_with("current") { 0.0 } else { number(d)?.0 };
        FieldKind::Number { min: None, max: None, value, whole: value.fract() == 0.0 }
    };
    Some(ParamField { name: name.into(), kind })
}

/// A choice spelled as a value (`horizontalOnly`, `display-p3`, `JPEG High`), not a placeholder.
fn is_word(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || " -_".contains(c)) && s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
}

/// A leading number of `s` and what follows it (`0.1..5` → `0.1`, `..5`).
fn number(s: &str) -> Option<(f64, &str)> {
    let b = s.as_bytes();
    let mut end = usize::from(b.first() == Some(&b'-'));
    let digits = |from: usize| b.get(from..).map_or(0, |t| t.iter().take_while(|c| c.is_ascii_digit()).count());
    let int = digits(end);
    if int == 0 {
        return None;
    }
    end += int;
    if b.get(end) == Some(&b'.') && b.get(end + 1).is_some_and(u8::is_ascii_digit) {
        end += 1 + digits(end + 1);
    }
    Some((s.get(..end)?.parse().ok()?, s.get(end..)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn num(min: f64, max: f64, value: f64, whole: bool) -> FieldKind {
        FieldKind::Number { min: Some(min), max: Some(max), value, whole }
    }

    #[test]
    fn reads_ranges_choices_and_toggles() {
        let f = fields(
            r##"{"radius":0.1..1000=1,"levels":2..255=4,"angle":-360..360,"mode":"normal|horizontalOnly"="horizontalOnly","color":"#rrggbb|[r,g,b,a]"=foreground,"mono":bool=true,"name":str?,"label":str="Cut","seed":u32=0,"dx":px=5,"red":json} (notes, with "commas")"##,
        );
        let kinds: Vec<_> = f.iter().map(|f| (f.name.as_str(), &f.kind)).collect();
        assert_eq!(
            kinds,
            [
                ("radius", &num(0.1, 1000.0, 1.0, false)),
                ("levels", &num(2.0, 255.0, 4.0, true)),
                ("angle", &num(-360.0, 360.0, 0.0, true)),
                ("mode", &FieldKind::Choice { options: vec!["normal".into(), "horizontalOnly".into()], value: "horizontalOnly".into() }),
                ("color", &FieldKind::Color { options: Vec::new(), value: String::new() }),
                ("mono", &FieldKind::Toggle { value: true }),
                ("name", &FieldKind::Text { value: String::new() }),
                ("label", &FieldKind::Text { value: "Cut".into() }),
                ("dx", &FieldKind::Number { min: None, max: None, value: 5.0, whole: true }),
            ]
        );
    }

    #[test]
    fn colours_keep_their_named_choices() {
        let f = fields(r##"{"extensionColor":"background|foreground|transparent|#rrggbb"="background","tint":"#rrggbb","c":color}"##);
        let kinds: Vec<_> = f.iter().map(|f| &f.kind).collect();
        assert_eq!(
            kinds,
            [
                &FieldKind::Color { options: vec!["background".into(), "foreground".into(), "transparent".into()], value: "background".into() },
                &FieldKind::Color { options: Vec::new(), value: String::new() },
                &FieldKind::Color { options: Vec::new(), value: String::new() },
            ]
        );
    }

    #[test]
    fn odd_docs_give_no_fields() {
        for doc in ["", "{}", "{", "no object", r#"{"x":}"#, r#"{"":1..2}"#, r#"{"a":-..5}"#, "{\"é\":1..2=1}"] {
            assert!(fields(doc).is_empty(), "{doc}");
        }
    }

    #[test]
    fn a_size_that_starts_at_the_documents_is_a_field() {
        let f = fields(r#"{"width":px=current,"height":px=current,"x":px,"relative":bool=false}"#);
        let names: Vec<&str> = f.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["width", "height", "relative"]);
        assert_eq!(f[0].kind, FieldKind::Number { min: None, max: None, value: 0.0, whole: true });
    }
}

