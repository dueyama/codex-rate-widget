# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] - 2026-08-21

### Changed

- Removed the inexact local per-project token estimate and expanded the large widget's official token and remaining-capacity charts into the freed space.

### Fixed

- Separated the remaining-history start date from the 0% axis label in the expanded large-widget chart.
- Clarified that remaining history is account-wide capacity observed and stored by this Mac.
- Increased the visibility of the 100%, 50%, and 0% remaining-capacity reference lines.
- Added a weekly reference arc beneath the actual ring so faster-than-linear consumption is visible before and after the warning threshold.

## [1.1.1] - 2026-08-08

### Added

- A menu-bar language selector with System Default, English, and Japanese options.
- Shared App Group language preferences so the menu app and every widget size switch together.

### Changed

- Explicit-language rendering now applies consistently to localized text, dates, durations, and compact token units.

## [1.1.0] - 2026-08-08

### Added

- Interactive large-widget switching between official daily token usage and locally recorded remaining-capacity history.
- Twenty-four-hour and seven-day time scales for five-hour and weekly remaining-capacity observations.
- Bounded, atomic seven-day history storage with 15-minute deduplication and explicit gaps at missing windows and recording pauses.

## [1.0.2] - 2026-08-06

### Added

- Official weekly reset date and remaining time in the menu app and widgets.

## [1.0.1] - 2026-07-17

### Changed

- Added dates and token labels to the official seven-day daily-usage chart.

## [1.0.0] - 2026-07-17

### Added

- macOS menu-bar app with automatic 15-minute refresh and Launch at Login control.
- Small, medium, and large WidgetKit views for active Codex limits.
- Official daily and lifetime token totals when returned by Codex.
- Clearly labeled local per-project estimates based on read-only Codex thread metadata.
- English fallback and Japanese localization.
- Source-installation, privacy, security, public-audit, and maintenance documentation.
