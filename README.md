# Appcircle Xcode Select

This component is used to specify the Xcode version to be used during the build process.

Required Input Variables
- `$AC_XCODE_LIST_DIR`: Specifies the xcode folder list directory. Current xcode folder structure examples : /Applications/Xcode/10.3/Xcode or /Applications/Xcode/11.0/Xcode
- `$AC_XCODE_VERSION`: Specifies the xcode version.

Output Variables
- `$XCODE_DEVELOPER_DIR_PATH`: Xcode developer directory path.

## Running tests

Requires [RSpec](https://rspec.info) gem and Ruby standard library (Coverage). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

A coverage report is printed at the end of each run.
