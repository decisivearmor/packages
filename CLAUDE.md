# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the official Flutter packages repository containing first-party Flutter plugins. It uses a monorepo structure with federated plugins.

### Key Directories
- `packages/`: First-party Flutter packages
- `third_party/packages/`: Packages maintained by Flutter team but originally created by third parties
- `script/tool/`: Custom Flutter plugin tools for development tasks

## Development Commands

All development tasks use the custom Flutter plugin tools. First setup the tools:
```bash
cd script/tool && dart pub get && cd ../../
```

Then use these commands (replace `package_name` with the actual package):
```bash
# Format code
dart run script/tool/bin/flutter_plugin_tools.dart format --packages package_name

# Analyze code
dart run script/tool/bin/flutter_plugin_tools.dart analyze --packages package_name

# Run tests
dart run script/tool/bin/flutter_plugin_tools.dart test --packages package_name

# Build example apps
dart run script/tool/bin/flutter_plugin_tools.dart build-examples --apk --packages package_name

# Run integration tests
dart run script/tool/bin/flutter_plugin_tools.dart drive-examples --android --packages package_name

# Run native tests
dart run script/tool/bin/flutter_plugin_tools.dart native-test --ios --android --packages package_name

# Update code excerpts in READMEs
dart run script/tool/bin/flutter_plugin_tools.dart update-excerpts --packages package_name

# Update version and CHANGELOG
dart run script/tool/bin/flutter_plugin_tools.dart update-release-info --packages package_name
```

## Architecture Patterns

### Federated Plugin Structure
Most plugins follow this pattern:
1. **Platform interface package** (e.g., `video_player_platform_interface/`) - Defines the API contract
2. **Platform implementations** (e.g., `video_player_android/`, `video_player_avfoundation/`) - Platform-specific code
3. **Main package** (e.g., `video_player/`) - Ties everything together, exports the API

### Code Standards
- Uses `flutter_lints` with strict analysis defined in `analysis_options.yaml`
- C++ code must be formatted with clang version 15.0.0
- All PRs require tests (unit, native, or integration)
- README code snippets are managed via code excerpts

## Key Development Notes
- Issues should be filed in the main Flutter repository, not here
- PRs are automatically assigned to code owners (see CODEOWNERS file)
- The repository has extensive CI/CD automation
- When modifying platform-specific code, ensure changes are compatible across all supported platforms
- Integration tests use the `integration_test` package pattern

## Important: Local Development Only
- This is a local fork/clone of the Flutter packages repository
- Changes made here are for local use only
- DO NOT create pull requests to the upstream Flutter repository
- Any modifications should be maintained locally or in a private fork