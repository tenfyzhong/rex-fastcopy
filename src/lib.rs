use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io::Write;
use std::ops::Range;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, anyhow, bail};
use regex::Regex;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Match {
    pub name: String,
    pub full: Range<usize>,
    pub selection: Range<usize>,
}

impl Match {
    pub fn new(name: impl Into<String>, range: Range<usize>) -> Self {
        Self {
            name: name.into(),
            full: range.clone(),
            selection: range,
        }
    }
}

#[derive(Debug)]
struct NamedRegex {
    name: String,
    regex: Regex,
}

#[derive(Debug)]
pub struct MatcherSet {
    matchers: Vec<NamedRegex>,
}

impl MatcherSet {
    pub fn defaults() -> Self {
        Self::from_patterns(default_patterns()).expect("built-in regexes must compile")
    }

    pub fn from_patterns<I, N, P>(patterns: I) -> Result<Self>
    where
        I: IntoIterator<Item = (N, P)>,
        N: AsRef<str>,
        P: AsRef<str>,
    {
        let mut matchers = Vec::new();
        for (name, pattern) in patterns {
            let name = name.as_ref();
            if name.is_empty() {
                bail!("regex must have a name");
            }
            if pattern.as_ref().is_empty() {
                continue;
            }
            let regex =
                Regex::new(pattern.as_ref()).with_context(|| format!("compile regex {name:?}"))?;
            matchers.push(NamedRegex {
                name: name.to_owned(),
                regex,
            });
        }
        Ok(Self { matchers })
    }

    pub fn with_overrides<I, N, P>(overrides: I) -> Result<Self>
    where
        I: IntoIterator<Item = (N, P)>,
        N: AsRef<str>,
        P: AsRef<str>,
    {
        let mut patterns = default_patterns()
            .into_iter()
            .map(|(name, pattern)| (name.to_owned(), pattern.to_owned()))
            .collect::<Vec<_>>();

        for (name, pattern) in overrides {
            let name = name.as_ref();
            if name.is_empty() {
                bail!("regex must have a name");
            }
            patterns.retain(|(existing, _)| existing != name);
            if !pattern.as_ref().is_empty() {
                patterns.push((name.to_owned(), pattern.as_ref().to_owned()));
            }
        }

        Self::from_patterns(patterns)
    }

    pub fn find(&self, text: &str) -> Vec<Match> {
        let mut found = Vec::new();
        for matcher in &self.matchers {
            for captures in matcher.regex.captures_iter(text) {
                let Some(full) = captures.get(0) else {
                    continue;
                };
                let selection = captures.get(1).unwrap_or(full);
                found.push(Match {
                    name: matcher.name.clone(),
                    full: full.range(),
                    selection: selection.range(),
                });
            }
        }

        found.sort_by(|left, right| {
            left.full
                .start
                .cmp(&right.full.start)
                .then_with(|| right.full.len().cmp(&left.full.len()))
        });

        let mut non_overlapping: Vec<Match> = Vec::with_capacity(found.len());
        for matched in found {
            if non_overlapping
                .last()
                .is_some_and(|previous| matched.full.start < previous.full.end)
            {
                continue;
            }
            non_overlapping.push(matched);
        }
        non_overlapping
    }
}

fn default_patterns() -> [(&'static str, &'static str); 8] {
    [
        ("ipv4", r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),
        ("gitsha", r"\b[0-9a-f]{7,40}\b"),
        ("hexaddr", r"(?i:\b0x[0-9a-f]{2,}\b)"),
        ("hexcolor", r"(?i:#(?:[0-9a-f]{3}|[0-9a-f]{6})\b)"),
        ("int", r"(?:-?|\b)\d{4,}\b"),
        ("path", r"(?:[\w.~-]+)?(?:/[\w.-]+){2,}\b"),
        (
            "uuid",
            r"(?i:\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b)",
        ),
        ("isodate", r"\d{4}-\d{2}-\d{2}"),
    ]
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Hint {
    pub label: String,
    pub text: String,
    pub occurrences: Vec<Match>,
}

pub fn generate_hints(alphabet: &str, text: &str, matches: &[Match]) -> Result<Vec<Hint>> {
    let alphabet = validate_alphabet(alphabet)?;
    let mut grouped: BTreeMap<&str, Vec<Match>> = BTreeMap::new();
    for matched in matches {
        let Some(value) = text.get(matched.selection.clone()) else {
            bail!("match range is not on UTF-8 boundaries");
        };
        grouped.entry(value).or_default().push(matched.clone());
    }

    let width = label_width(alphabet.len(), grouped.len());
    Ok(grouped
        .into_iter()
        .enumerate()
        .map(|(index, (value, occurrences))| Hint {
            label: encode_label(index, width, &alphabet),
            text: value.to_owned(),
            occurrences,
        })
        .collect())
}

fn validate_alphabet(alphabet: &str) -> Result<Vec<char>> {
    let alphabet = alphabet.chars().collect::<Vec<_>>();
    if alphabet.len() < 2 {
        bail!("alphabet must have at least two characters");
    }
    let unique = alphabet.iter().copied().collect::<HashSet<_>>();
    if unique.len() != alphabet.len() {
        bail!("alphabet characters must be unique");
    }
    Ok(alphabet)
}

fn label_width(base: usize, count: usize) -> usize {
    let mut width = 1;
    let mut capacity = base;
    while capacity < count {
        width += 1;
        capacity = capacity.saturating_mul(base);
    }
    width
}

fn encode_label(mut index: usize, width: usize, alphabet: &[char]) -> String {
    let mut label = vec![alphabet[0]; width];
    for place in (0..width).rev() {
        label[place] = alphabet[index % alphabet.len()];
        index /= alphabet.len();
    }
    label.into_iter().collect()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppEvent {
    Char(char),
    Backspace,
    Tab,
    Enter,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Selection {
    pub text: String,
    pub matcher_names: Vec<String>,
    pub shifted: bool,
}

#[derive(Debug)]
pub struct AppState {
    hints: Vec<Hint>,
    input: String,
    selected: BTreeSet<usize>,
    multi_select: bool,
    shifted: bool,
}

impl AppState {
    pub fn new(hints: Vec<Hint>) -> Self {
        Self {
            hints,
            input: String::new(),
            selected: BTreeSet::new(),
            multi_select: false,
            shifted: false,
        }
    }

    pub fn input(&self) -> &str {
        &self.input
    }

    pub fn is_multi_select(&self) -> bool {
        self.multi_select
    }

    pub fn is_selected(&self, index: usize) -> bool {
        self.selected.contains(&index)
    }

    pub fn handle(&mut self, event: AppEvent) -> Option<Selection> {
        match event {
            AppEvent::Backspace => {
                self.input.pop();
                None
            }
            AppEvent::Tab if !self.multi_select => {
                self.multi_select = true;
                None
            }
            AppEvent::Tab | AppEvent::Enter if self.multi_select => self.selection(),
            AppEvent::Tab => None,
            AppEvent::Enter => None,
            AppEvent::Char(ch) => {
                if ch.is_uppercase() {
                    self.shifted = true;
                }
                let normalized = ch.to_lowercase().next().unwrap_or(ch);
                self.input.push(normalized);

                let matched = self.hints.iter().position(|hint| hint.label == self.input);
                let index = matched?;

                if !self.selected.insert(index) {
                    self.selected.remove(&index);
                }
                self.input.clear();

                if self.multi_select {
                    None
                } else {
                    self.selection()
                }
            }
        }
    }

    fn selection(&self) -> Option<Selection> {
        if self.selected.is_empty() {
            return None;
        }

        let text = self
            .selected
            .iter()
            .map(|index| self.hints[*index].text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let matcher_names = self
            .selected
            .iter()
            .flat_map(|index| &self.hints[*index].occurrences)
            .map(|matched| matched.name.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();

        Some(Selection {
            text,
            matcher_names,
            shifted: self.shifted,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActionInput {
    pub program: String,
    pub args: Vec<String>,
    pub stdin: Option<String>,
}

pub fn build_action(action: &str, selection: &str) -> Result<ActionInput> {
    let mut words = shell_words::split(action).context("parse action")?;
    if words.is_empty() {
        bail!("action must not be empty");
    }
    let program = words.remove(0);
    if let Some(position) = words.iter().position(|word| word == "{}") {
        words[position] = selection.to_owned();
        Ok(ActionInput {
            program,
            args: words,
            stdin: None,
        })
    } else {
        Ok(ActionInput {
            program,
            args: words,
            stdin: Some(selection.to_owned()),
        })
    }
}

pub fn run_action(action: &str, selection: &Selection, pane: &str) -> Result<()> {
    let input = build_action(action, &selection.text)?;
    let mut command = Command::new(&input.program);
    command
        .args(&input.args)
        .env("FASTCOPY_REGEX_NAME", selection.matcher_names.join(" "))
        .env("FASTCOPY_TARGET_PANE_ID", pane);

    if input.stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command
        .spawn()
        .with_context(|| format!("run action {:?}", input.program))?;
    if let Some(stdin) = input.stdin {
        child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("action stdin was not available"))?
            .write_all(stdin.as_bytes())
            .context("write selection to action")?;
    }
    let status = child.wait().context("wait for action")?;
    if !status.success() {
        bail!("action exited with {status}");
    }
    Ok(())
}

/// Parse the output of `show-options -g` into `(name, value)` pairs.
///
/// This mirrors how tmux-fastcopy reads `@fastcopy-*` options: tmux and rmux
/// print option values as tmux-quoted strings (double-quoted when they contain
/// spaces, with backslashes and quotes escaped), and this undoes that quoting
/// so the stored value is recovered.
///
/// Lines without a value (for example an option set to an empty string)
/// produce an empty value.
pub fn parse_show_options(output: &str) -> Vec<(String, String)> {
    output
        .lines()
        .filter_map(|line| {
            let (name, value) = match line.split_once(' ') {
                Some((name, value)) => (name.trim(), value.trim_start()),
                None => (line.trim(), ""),
            };
            if name.is_empty() {
                return None;
            }
            Some((name.to_owned(), unquote_option(value)))
        })
        .collect()
}

/// Unquote a single option value as printed by `show-options -g`.
///
/// tmux and rmux escape values when printing them; in particular every
/// backslash is doubled. This recovers the original value, using the same
/// strategy as tmux-fastcopy's `tmuxopt.Unquote`.
fn unquote_option(value: &str) -> String {
    if value.is_empty() {
        return String::new();
    }

    if value.starts_with('\'') && value.ends_with('\'') {
        // Single-quoted: swap quotes so the inner content can be parsed as a
        // double-quoted literal, then swap back.
        let inverted = invert_quotes(value);
        return invert_quotes(&unquote_double(&inverted));
    }

    let quoted = if value.starts_with('"') && value.ends_with('"') {
        value.to_owned()
    } else if !value.contains('"') {
        // Unquoted values still escape backslashes; wrap them so they go
        // through the same unescaping.
        format!("\"{value}\"")
    } else {
        return value.to_owned();
    };
    unquote_double(&quoted)
}

/// Parse a double-quoted string literal, undoing tmux/rmux escaping.
fn unquote_double(value: &str) -> String {
    let Some(inner) = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')) else {
        return value.to_owned();
    };

    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('"') => out.push('"'),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            // Unknown escapes (\d, \s, \b, ...) are preserved literally so
            // regex patterns survive unchanged.
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

fn invert_quotes(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            '\'' => '"',
            '"' => '\'',
            ch => ch,
        })
        .collect()
}
