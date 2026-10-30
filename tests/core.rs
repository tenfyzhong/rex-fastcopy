use std::collections::HashSet;

use pretty_assertions::assert_eq;
use rex_fastcopy::{
    ActionInput, AppEvent, AppState, Match, MatcherSet, Selection, build_action, generate_hints,
    parse_show_options,
};

#[test]
fn default_matchers_find_the_reference_plugin_text_types() {
    let text = concat!(
        "host 192.168.1.20 sha deadbeef path src/module/file.rs ",
        "uuid 123e4567-e89b-12d3-a456-426614174000 date 2026-08-10 ",
        "address 0xCAFE color #c0ffee count 12345",
    );

    let found: HashSet<_> = MatcherSet::defaults()
        .find(text)
        .into_iter()
        .map(|matched| (matched.name, &text[matched.selection]))
        .collect();

    assert!(found.contains(&("ipv4".into(), "192.168.1.20")));
    assert!(found.contains(&("gitsha".into(), "deadbeef")));
    assert!(found.contains(&("path".into(), "src/module/file.rs")));
    assert!(found.contains(&("uuid".into(), "123e4567-e89b-12d3-a456-426614174000")));
    assert!(found.contains(&("isodate".into(), "2026-08-10")));
    assert!(found.contains(&("hexaddr".into(), "0xCAFE")));
    assert!(found.contains(&("hexcolor".into(), "#c0ffee")));
    assert!(found.contains(&("int".into(), "12345")));
}

#[test]
fn matcher_uses_first_capture_group_and_removes_overlaps() {
    let matchers = MatcherSet::from_patterns([
        ("short", r"ticket-(\d+)"),
        ("long", r"ticket-\d+"),
        ("later", r"\d+"),
    ])
    .unwrap();

    assert_eq!(
        matchers.find("ticket-1234"),
        vec![Match {
            name: "short".into(),
            full: 0..11,
            selection: 7..11,
        }]
    );
}

#[test]
fn hints_group_duplicate_text_and_are_prefix_free() {
    let text = "foo 192.0.2.1 then 192.0.2.1 and 2026-08-10";
    let matches = MatcherSet::defaults().find(text);
    let hints = generate_hints("ab", text, &matches).unwrap();

    let ip = hints.iter().find(|hint| hint.text == "192.0.2.1").unwrap();
    assert_eq!(ip.occurrences.len(), 2);

    for (index, left) in hints.iter().enumerate() {
        for right in hints.iter().skip(index + 1) {
            assert!(!left.label.starts_with(&right.label));
            assert!(!right.label.starts_with(&left.label));
        }
    }
}

#[test]
fn single_selection_accepts_a_label_immediately() {
    let hints = generate_hints(
        "ab",
        "one two",
        &[Match::new("word", 0..3), Match::new("word", 4..7)],
    )
    .unwrap();
    let expected = hints[0].text.clone();
    let label = hints[0].label.clone();
    let mut state = AppState::new(hints);

    let mut result = None;
    for ch in label.chars() {
        result = state.handle(AppEvent::Char(ch));
    }

    assert_eq!(
        result,
        Some(Selection {
            text: expected,
            matcher_names: vec!["word".into()],
            shifted: false,
        })
    );
}

#[test]
fn tab_mode_toggles_multiple_labels_and_joins_them() {
    let hints = generate_hints(
        "ab",
        "one two",
        &[Match::new("first", 0..3), Match::new("second", 4..7)],
    )
    .unwrap();
    let expected = hints
        .iter()
        .map(|hint| hint.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let labels = hints
        .iter()
        .map(|hint| hint.label.clone())
        .collect::<Vec<_>>();
    let mut state = AppState::new(hints);

    assert_eq!(state.handle(AppEvent::Tab), None);
    for label in labels {
        for ch in label.chars() {
            assert_eq!(state.handle(AppEvent::Char(ch)), None);
        }
    }

    assert_eq!(
        state.handle(AppEvent::Enter),
        Some(Selection {
            text: expected,
            matcher_names: vec!["first".into(), "second".into()],
            shifted: false,
        })
    );
}

#[test]
fn uppercase_label_selects_the_shift_action() {
    let hints = generate_hints("ab", "value", &[Match::new("word", 0..5)]).unwrap();
    let label = hints[0].label.to_uppercase();
    let mut state = AppState::new(hints);

    let mut result = None;
    for ch in label.chars() {
        result = state.handle(AppEvent::Char(ch));
    }

    assert!(result.unwrap().shifted);
}

#[test]
fn action_uses_stdin_without_placeholder() {
    assert_eq!(
        build_action("rmux load-buffer -", "hello world").unwrap(),
        ActionInput {
            program: "rmux".into(),
            args: vec!["load-buffer".into(), "-".into()],
            stdin: Some("hello world".into()),
        }
    );
}

#[test]
fn action_replaces_the_first_placeholder() {
    assert_eq!(
        build_action("open {} --fresh", "/tmp/a b").unwrap(),
        ActionInput {
            program: "open".into(),
            args: vec!["/tmp/a b".into(), "--fresh".into()],
            stdin: None,
        }
    );
}

#[test]
fn show_options_parses_quoted_unescaped_and_empty_values() {
    let options = parse_show_options(concat!(
        "@fastcopy-action \"rmux load-buffer -\"\n",
        r"@fastcopy-regex-word \\b[^\\s]+\\b",
        "\n@fastcopy-empty\n",
    ));

    assert_eq!(
        options,
        vec![
            ("@fastcopy-action".into(), "rmux load-buffer -".into()),
            ("@fastcopy-regex-word".into(), r"\b[^\s]+\b".into()),
            ("@fastcopy-empty".into(), String::new()),
        ]
    );
}

#[test]
fn show_options_unescapes_embedded_quotes() {
    assert_eq!(
        parse_show_options(concat!("@fastcopy-say ", r#""say \"hi\"""#, "\n")),
        vec![("@fastcopy-say".into(), r#"say "hi""#.into())]
    );
}

#[test]
fn show_options_parses_single_quoted_values() {
    assert_eq!(
        parse_show_options(concat!("@fastcopy-say ", "'say \"hi\"'", "\n")),
        vec![("@fastcopy-say".into(), r#"say "hi""#.into())]
    );
}

#[test]
fn word_regex_selects_arbitrary_words() {
    let text = "hello world foo.bar, 42";
    let matchers = MatcherSet::from_patterns([("word", r"\b[^\s]+\b")]).unwrap();
    let found: Vec<_> = matchers
        .find(text)
        .into_iter()
        .map(|matched| &text[matched.selection])
        .collect();

    assert_eq!(found, vec!["hello", "world", "foo.bar", "42"]);
}
