// Adapted from rmux-fastcopy; see NOTICE and LICENSE.
use anyhow::{Context, Result};
use clap::Parser;
use crossterm::cursor::{Hide, MoveTo, Show};
use crossterm::event::{
    self, DisableFocusChange, EnableFocusChange, Event, KeyCode, KeyEventKind, KeyModifiers,
};
use crossterm::style::{
    Attribute, Color, Print, SetAttribute, SetBackgroundColor, SetForegroundColor,
};
use crossterm::terminal::{
    Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode,
    enable_raw_mode, size,
};
use crossterm::{execute, queue};
use rex_fastcopy::{AppEvent, AppState, Hint, MatcherSet, Selection, generate_hints, run_action};
use std::collections::HashMap;
use std::io::{self, Stdout, Write};
use std::path::PathBuf;
use std::time::Duration;
use unicode_width::UnicodeWidthChar;

#[derive(Debug, Parser)]
#[command(version, about = "Label-based text copying for Rex")]
struct Args {
    /// Private screen snapshot, removed immediately after reading.
    #[arg(long)]
    snapshot: PathBuf,
    /// Target pane rectangle as window fractions x,y,width,height.
    #[arg(long, default_value = "0,0,1,1", value_parser = parse_region)]
    region: [f64; 4],
    /// Native horizontal window padding expressed in terminal columns.
    #[arg(long, default_value_t = 0.0)]
    padding_columns: f64,
    /// Neighbor snapshot as x,y,width,height:path; may be repeated.
    #[arg(long, value_parser = parse_background)]
    background: Vec<Background>,
    #[arg(long, default_value = "/usr/bin/pbcopy")]
    action: String,
    #[arg(long)]
    shift_action: Option<String>,
    #[arg(long, default_value = "abcdefghijklmnopqrstuvwxyz")]
    alphabet: String,
    #[arg(long = "regex", value_parser = parse_regex)]
    regexes: Vec<(String, String)>,
    #[arg(long, default_value = "")]
    pane: String,
    /// Rex CLI used to restore the original pane's focus before the overlay exits.
    #[arg(long)]
    rex: Option<PathBuf>,
    #[arg(long, requires = "rex")]
    session: Option<String>,
}

#[derive(Clone, Debug)]
struct Background {
    region: [f64; 4],
    content: String,
}

fn parse_background(value: &str) -> Result<Background, String> {
    let (region, path) = value.split_once(':').ok_or("expected region:path")?;
    Ok(Background {
        region: parse_region(region)?,
        content: path.to_owned(),
    })
}

fn parse_region(value: &str) -> Result<[f64; 4], String> {
    let parts = value
        .split(',')
        .map(str::parse::<f64>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "region must be x,y,width,height")?;
    let rect: [f64; 4] = parts
        .try_into()
        .map_err(|_| "region must have four numbers")?;
    if rect.iter().any(|v| !v.is_finite() || *v < 0.0)
        || rect[2] <= 0.0
        || rect[3] <= 0.0
        || rect[0] + rect[2] > 1.000001
        || rect[1] + rect[3] > 1.000001
    {
        return Err("region must fit inside the window".into());
    }
    Ok(rect)
}

fn parse_regex(value: &str) -> Result<(String, String), String> {
    let (name, pattern) = value.split_once(':').ok_or("expected NAME:PATTERN")?;
    if name.is_empty() {
        return Err("regex name must not be empty".into());
    }
    Ok((name.to_owned(), pattern.to_owned()))
}

fn main() {
    let args = Args::parse();
    let result = run(&args);
    if result.as_ref().copied().unwrap_or(true)
        && let (Some(rex), Some(session)) = (&args.rex, &args.session)
    {
        let focus = std::process::Command::new(rex)
            .args(["--autostart=false", "focus", "-s", session, &args.pane])
            .output();
        if !focus.is_ok_and(|output| output.status.success()) {
            eprintln!("rex-fastcopy: could not restore the original pane's focus");
        }
    }
    if let Err(error) = result {
        eprintln!("rex-fastcopy: {error:#}");
        std::process::exit(1);
    }
}

fn run(args: &Args) -> Result<bool> {
    let captured = std::fs::read_to_string(&args.snapshot);
    let removed = std::fs::remove_file(&args.snapshot);
    let backgrounds = args
        .background
        .iter()
        .map(|background| {
            let content = std::fs::read_to_string(&background.content);
            let removed = std::fs::remove_file(&background.content);
            content.and_then(|content| {
                removed.map(|()| Background {
                    region: background.region,
                    content,
                })
            })
        })
        .collect::<Vec<_>>();
    let backgrounds = backgrounds
        .into_iter()
        .collect::<std::io::Result<Vec<_>>>()?;
    let text = captured.context("read snapshot")?;
    removed.context("remove snapshot")?;
    let matchers = MatcherSet::with_overrides(args.regexes.clone())?;
    let hints = generate_hints(&args.alphabet, &text, &matchers.find(&text))?;
    let (selection, restore_focus) = run_ui(
        &text,
        &hints,
        args.region,
        &backgrounds,
        args.padding_columns,
    )?;
    if let Some(selection) = selection {
        let action = if selection.shifted {
            args.shift_action.as_deref().unwrap_or(&args.action)
        } else {
            &args.action
        };
        run_action(action, &selection, &args.pane)?;
    }
    Ok(restore_focus)
}

struct Terminal {
    stdout: Stdout,
}

impl Terminal {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("enable raw terminal mode")?;
        let mut stdout = io::stdout();
        if let Err(error) = execute!(stdout, EnterAlternateScreen, Hide, EnableFocusChange) {
            let _ = disable_raw_mode();
            return Err(error).context("enter alternate screen");
        }
        Ok(Self { stdout })
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = execute!(self.stdout, DisableFocusChange, Show, LeaveAlternateScreen);
        let _ = disable_raw_mode();
    }
}

fn run_ui(
    text: &str,
    hints: &[Hint],
    region: [f64; 4],
    backgrounds: &[Background],
    padding_columns: f64,
) -> Result<(Option<Selection>, bool)> {
    crossterm::style::force_color_output(true);
    let mut terminal = Terminal::enter()?;
    let mut state = AppState::new(hints.to_vec());
    render(
        &mut terminal.stdout,
        text,
        hints,
        &state,
        region,
        backgrounds,
        padding_columns,
    )?;

    loop {
        if !event::poll(Duration::from_secs(30)).context("poll terminal input")? {
            continue;
        }
        let event = event::read().context("read terminal input")?;
        match event {
            Event::FocusLost => return Ok((None, false)),
            Event::Resize(_, _) => render(
                &mut terminal.stdout,
                text,
                hints,
                &state,
                region,
                backgrounds,
                padding_columns,
            )?,
            Event::Key(key) if key.kind == KeyEventKind::Press => {
                let app_event = match key.code {
                    KeyCode::Esc => return Ok((None, true)),
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        return Ok((None, true));
                    }
                    KeyCode::Backspace => Some(AppEvent::Backspace),
                    KeyCode::Tab | KeyCode::BackTab => Some(AppEvent::Tab),
                    KeyCode::Enter => Some(AppEvent::Enter),
                    KeyCode::Char(mut ch) => {
                        if key.modifiers.contains(KeyModifiers::SHIFT) {
                            ch = ch.to_uppercase().next().unwrap_or(ch);
                        }
                        Some(AppEvent::Char(ch))
                    }
                    _ => None,
                };
                if let Some(app_event) = app_event {
                    if let Some(selection) = state.handle(app_event) {
                        return Ok((Some(selection), true));
                    }
                    render(
                        &mut terminal.stdout,
                        text,
                        hints,
                        &state,
                        region,
                        backgrounds,
                        padding_columns,
                    )?;
                }
            }
            _ => {}
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CellStyle {
    Normal,
    Match,
    Skipped,
    Selected,
    Label,
    LabelTyped,
    DeselectLabel,
}

#[derive(Clone, Copy)]
struct Cell {
    byte_offset: usize,
    ch: char,
    style: CellStyle,
}

struct Viewport {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

fn render(
    stdout: &mut Stdout,
    text: &str,
    hints: &[Hint],
    state: &AppState,
    region: [f64; 4],
    backgrounds: &[Background],
    padding_columns: f64,
) -> Result<()> {
    let (columns, rows) = size().context("read terminal size")?;
    queue!(
        stdout,
        SetAttribute(Attribute::Reset),
        Clear(ClearType::All)
    )?;
    let empty = AppState::new(Vec::new());
    for background in backgrounds {
        render_region(
            stdout,
            &background.content,
            &[],
            &empty,
            viewport(background.region, columns, rows, padding_columns),
            false,
        )?;
    }
    render_region(
        stdout,
        text,
        hints,
        state,
        viewport(region, columns, rows, padding_columns),
        true,
    )
}

fn viewport(region: [f64; 4], columns: u16, rows: u16, padding_columns: f64) -> Viewport {
    let content_columns = (f64::from(columns) - padding_columns).max(0.0);
    let x = (region[0] * f64::from(columns)).round() as u16;
    let y = (region[1] * f64::from(rows)).round() as u16;
    let width = ((region[2] * content_columns).round() as u16).min(columns.saturating_sub(x));
    let height = ((region[3] * f64::from(rows)).round() as u16).min(rows.saturating_sub(y));
    Viewport {
        x,
        y,
        width,
        height,
    }
}

#[cfg(test)]
fn render_frame(
    stdout: &mut impl Write,
    text: &str,
    hints: &[Hint],
    state: &AppState,
    width: u16,
    height: u16,
) -> Result<()> {
    render_region(
        stdout,
        text,
        hints,
        state,
        Viewport {
            x: 0,
            y: 0,
            width,
            height,
        },
        true,
    )
}

fn render_region(
    stdout: &mut impl Write,
    text: &str,
    hints: &[Hint],
    state: &AppState,
    viewport: Viewport,
    show_empty: bool,
) -> Result<()> {
    let Viewport {
        x: origin_x,
        y: origin_y,
        width,
        height,
    } = viewport;
    let mut cells = text
        .char_indices()
        .map(|(byte_offset, ch)| Cell {
            byte_offset,
            ch,
            style: CellStyle::Normal,
        })
        .collect::<Vec<_>>();
    let mut labels = Vec::new();
    for (hint_index, hint) in hints.iter().enumerate() {
        let selected = state.is_selected(hint_index);
        let candidate = hint.label.starts_with(state.input());
        for occurrence in &hint.occurrences {
            let match_style = if selected {
                CellStyle::Selected
            } else if candidate {
                CellStyle::Match
            } else {
                CellStyle::Skipped
            };
            for cell in cells.iter_mut().filter(|cell| {
                occurrence.selection.start <= cell.byte_offset
                    && cell.byte_offset < occurrence.selection.end
            }) {
                cell.style = match_style;
            }

            if !candidate && !selected {
                continue;
            }
            labels.push((occurrence.selection.start, &hint.label, selected));
        }
    }

    // Clear only this pane; previously painted neighboring panes stay visible.
    queue!(
        stdout,
        SetAttribute(Attribute::Reset),
        SetBackgroundColor(Color::Rgb {
            r: 30,
            g: 30,
            b: 46
        })
    )?;
    let blank = " ".repeat(width as usize);
    for row in 0..height {
        queue!(stdout, MoveTo(origin_x, origin_y + row), Print(&blank))?;
    }
    queue!(stdout, MoveTo(origin_x, origin_y))?;
    let mut x = 0_u16;
    let mut y = 0_u16;
    let mut active: Option<CellStyle> = None;
    let mut positions = HashMap::new();
    for cell in cells {
        if y >= height {
            break;
        }
        if cell.ch == '\n' {
            x = 0;
            y = y.saturating_add(1);
            active = None;
            continue;
        }
        if cell.ch == '\r' {
            x = 0;
            continue;
        }
        let cell_width = cell.ch.width().unwrap_or(0) as u16;
        if cell_width > 0 && x.saturating_add(cell_width) > width {
            // Snapshot lines are physical terminal rows. If the overlay has
            // shrunk, clip the row instead of reflowing it over subsequent rows.
            x = width;
            continue;
        }
        if y >= height {
            break;
        }

        positions.insert(cell.byte_offset, (x, y));
        if x == 0 {
            queue!(stdout, MoveTo(origin_x, origin_y + y))?;
        }
        if active != Some(cell.style) {
            let (color, bold) = style(cell.style);
            queue!(
                stdout,
                SetForegroundColor(color),
                SetAttribute(if bold {
                    Attribute::Bold
                } else {
                    Attribute::NormalIntensity
                })
            )?;
            active = Some(cell.style);
        }
        queue!(stdout, Print(cell.ch))?;
        x = x.saturating_add(cell_width);
    }

    // Paint labels after the text, using original terminal-cell coordinates.
    // This preserves wide characters and keeps short-token labels on one row.
    for (offset, label, selected) in labels {
        if let Some(&(x, y)) = positions.get(&offset) {
            let x = x.min(width.saturating_sub(label.len() as u16));
            let (color, _) = style(if selected {
                CellStyle::DeselectLabel
            } else {
                CellStyle::Label
            });
            queue!(
                stdout,
                MoveTo(origin_x + x, origin_y + y),
                SetForegroundColor(color),
                SetAttribute(Attribute::Bold),
                Print(label.chars().take(width as usize).collect::<String>())
            )?;
            if !selected && !state.input().is_empty() {
                let (color, _) = style(CellStyle::LabelTyped);
                queue!(
                    stdout,
                    MoveTo(origin_x + x, origin_y + y),
                    SetForegroundColor(color),
                    Print(state.input())
                )?;
            }
        }
    }

    if show_empty && hints.is_empty() && height > 0 {
        let message = "No copyable text found - Esc to close";
        queue!(
            stdout,
            MoveTo(origin_x, origin_y + height - 1),
            SetForegroundColor(Color::Yellow),
            SetAttribute(Attribute::Bold),
            Print(&message[..message.len().min(width as usize)])
        )?;
    }
    queue!(stdout, SetAttribute(Attribute::Reset))?;
    stdout.flush().context("draw fastcopy overlay")
}

fn style(style: CellStyle) -> (Color, bool) {
    match style {
        CellStyle::Normal => (Color::White, false),
        CellStyle::Match => (Color::Green, false),
        CellStyle::Skipped => (Color::DarkGrey, false),
        CellStyle::Selected => (Color::Yellow, false),
        CellStyle::Label => (Color::Red, true),
        CellStyle::LabelTyped => (Color::Yellow, true),
        CellStyle::DeselectLabel => (Color::DarkRed, true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_origins_include_window_padding_not_only_terminal_columns() {
        let right = viewport([0.5, 0.0, 0.5, 1.0], 240, 58, 2.0);
        assert_eq!(
            right.x, 120,
            "right pane must retain its own native left inset"
        );
        let left = viewport([0.0, 0.0, 0.5, 1.0], 240, 58, 2.0);
        assert_eq!(left.x, 0);
    }

    #[test]
    fn padded_overlay_preserves_full_width_source_lines() {
        let pane = viewport([0.5, 0.0, 0.5, 1.0], 240, 3, 2.0);
        assert_eq!((pane.x, pane.width), (120, 119));
        let text = format!("{}\n192.0.2.1", "x".repeat(119));
        let mut output = Vec::new();
        render_region(
            &mut output,
            &text,
            &[],
            &AppState::new(Vec::new()),
            pane,
            false,
        )
        .unwrap();
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("\x1b[2;121H"));
        assert!(output.contains("192.0.2.1"));
    }

    #[test]
    fn narrower_overlay_clips_without_moving_following_rows() {
        let text = "123456\nNEXT";
        let mut output = Vec::new();
        render_frame(&mut output, text, &[], &AppState::new(Vec::new()), 5, 3).unwrap();
        let output = String::from_utf8(output).unwrap();
        let next = output.find("NEXT").unwrap();
        let before = &output[..next];
        assert!(before.rfind("\x1b[2;1H").unwrap() > before.rfind("\x1b[3;1H").unwrap());
        assert!(!output.contains("123456"));
    }

    #[test]
    fn labels_do_not_cross_lines_or_shift_wide_characters() {
        crossterm::style::force_color_output(true);
        let text = "f\n中文 192.0.2.1";
        let matchers = MatcherSet::from_patterns([("word", r"\S+")]).unwrap();
        let hints = generate_hints("ab", text, &matchers.find(text)).unwrap();
        let state = AppState::new(hints.clone());
        let mut output = Vec::new();
        render_frame(&mut output, text, &hints, &state, 80, 4).unwrap();
        let output = String::from_utf8(output).unwrap();
        // Labels are a separate pass at original cell coordinates. In particular,
        // the short first token's second label character stays on the first row.
        let first = hints.iter().find(|h| h.text == "f").unwrap();
        let ip = hints.iter().find(|h| h.text == "192.0.2.1").unwrap();
        assert!(output.contains("\x1b[1;1H"));
        assert!(output.contains(&first.label));
        assert!(output.contains("\x1b[2;6H"));
        assert!(output.contains(&ip.label));
        assert!(output.contains("中文"));
    }

    #[test]
    fn right_pane_draws_at_offset_without_erasing_neighbor() {
        crossterm::style::force_color_output(true);
        let hints =
            generate_hints("ab", "192.0.2.1", &MatcherSet::defaults().find("192.0.2.1")).unwrap();
        let state = AppState::new(hints.clone());
        let mut output = Vec::new();
        render_region(
            &mut output,
            "192.0.2.1",
            &hints,
            &state,
            Viewport {
                x: 40,
                y: 0,
                width: 40,
                height: 12,
            },
            true,
        )
        .unwrap();
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("\x1b[1;41H"));
        assert!(!output.contains("\x1b[1;1H"));
        assert!(
            !output.contains("\x1b[2J"),
            "pane repaint must not clear neighbors"
        );
    }
}
