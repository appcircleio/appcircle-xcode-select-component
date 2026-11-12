# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

STEP_ENV_KEYS     = %w[AC_XCODE_LIST_DIR AC_XCODE_VERSION AC_ENV_FILE_PATH].freeze
XCODE_ROOT_DIR    = '/Applications/Xcode/'
DEVELOPER_SUFFIX  = 'Xcode.app/Contents/Developer'

# Saves and clears every variable the step reads, runs the block, then restores them.
def with_clean_env
  old = STEP_ENV_KEYS.to_h { |k| [k, ENV[k]] }
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  yield
ensure
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  old.each { |k, v| ENV[k] = v unless v.nil? }
end

def fake_status(success)
  double('Process::Status', success?: success)
end

# Stubs Open3.popen3 so no real command runs. Each call records the command and
# yields fake stdin/stdout/stderr streams plus a wait thread whose value is the
# next response's status; the last response is reused once exhausted.
def stub_popen3(*responses, recorder: nil)
  queue = responses.empty? ? [['', '', true]] : responses.dup
  allow(Open3).to receive(:popen3) do |cmd, &block|
    recorder&.<<(cmd)
    stdout, stderr, success = queue.size > 1 ? queue.shift : queue.first
    wait_thr = double('Process::Waiter', value: fake_status(success))
    block.call(StringIO.new, StringIO.new(stdout), StringIO.new(stderr), wait_thr)
  end
end

# Runs the block with $stdout and $stderr captured.
# Returns [stdout, stderr, SystemExit or nil].
def capture_io
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  exit_error = nil
  begin
    yield
  rescue SystemExit => e
    exit_error = e
  end
  [$stdout.string, $stderr.string, exit_error]
ensure
  $stdout = old_out
  $stderr = old_err
end

# Ruby's Coverage resets a file's counters on every `load`, so a snapshot is
# taken before each load and summed into the final report.
COVERAGE_SNAPSHOTS = []

def snapshot_coverage
  return unless defined?(Coverage) && Coverage.running?

  data = Coverage.peek_result[MAIN_RB]
  COVERAGE_SNAPSHOTS << data if data
end

# Runs main.rb's step body in-process with the given ENV.
# Returns [stdout, stderr, SystemExit or nil].
def run_step(env)
  with_clean_env do
    env.each { |k, v| ENV[k] = v }
    old_program_name = $PROGRAM_NAME
    $PROGRAM_NAME = MAIN_RB
    snapshot_coverage
    begin
      capture_io { load MAIN_RB }
    ensure
      $PROGRAM_NAME = old_program_name
    end
  end
end

# Stubs only the `/Applications/Xcode/` existence check that picks the path layout.
def stub_xcode_root(exists)
  allow(Dir).to receive(:exist?).and_call_original
  allow(Dir).to receive(:exist?).with(XCODE_ROOT_DIR).and_return(exists)
end

# Runs main.rb in a subprocess with the given ENV. Every variable the step reads
# is unset first (a nil value unsets it in the child), so the ambient
# environment cannot leak in.
def run_main(env = {})
  clean_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }
  Open3.capture3(clean_env.merge(env), "ruby #{MAIN_RB}")
end

# Writes fake `sudo` and `xcodebuild` executables into bin_dir. Both append their
# arguments to $FAKE_TOOL_LOG and never execute anything else, so the subprocess
# tests run the real step without touching the host toolchain.
#   FAKE_SUDO_FAIL=1       -> sudo prints an error to stderr and exits 1
#   FAKE_XCODEBUILD_FAIL=1 -> xcodebuild prints an error to stderr and exits 1
def write_fake_tools(bin_dir)
  FileUtils.mkdir_p(bin_dir)
  {
    'sudo' => <<~SH,
      #!/bin/sh
      echo "sudo $*" >> "$FAKE_TOOL_LOG"
      if [ "$FAKE_SUDO_FAIL" = "1" ]; then
        echo "xcode-select: error: invalid developer directory" >&2
        exit 1
      fi
    SH
    'xcodebuild' => <<~SH
      #!/bin/sh
      echo "xcodebuild $*" >> "$FAKE_TOOL_LOG"
      if [ "$FAKE_XCODEBUILD_FAIL" = "1" ]; then
        echo "xcodebuild: error: tool not found" >&2
        exit 1
      fi
      echo "Xcode 16.2"
      echo "Build version 16C5032a"
    SH
  }.each do |name, body|
    path = File.join(bin_dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end
  bin_dir
end

# Developer dir the step resolves on this host, mirroring the `/Applications/Xcode/` check.
def expected_developer_dir(list_dir, version)
  if Dir.exist?(XCODE_ROOT_DIR)
    "#{list_dir}/#{version}/#{DEVELOPER_SUFFIX}"
  else
    "/Volumes/xcode.#{version.split('.')[0...-1].join('.')}/#{DEVELOPER_SUFFIX}"
  end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = '16.2'
      expect(env_has_key('_TEST_VAR')).to eq('16.2')
    end

    it 'keeps whitespace-only values as-is' do
      ENV['_TEST_VAR'] = '  '
      expect(env_has_key('_TEST_VAR')).to eq('  ')
    end
  end

  context 'negative path' do
    it 'returns nil when the key is missing' do
      ENV.delete('_TEST_VAR')
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'raises TypeError for a nil key' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  let(:commands) { [] }

  context 'positive path' do
    it 'passes the command string to Open3.popen3 unchanged' do
      stub_popen3(['', '', true], recorder: commands)
      capture_io { run_command('sudo xcode-select --switch "/Xcode/Developer"') }
      expect(commands).to eq(['sudo xcode-select --switch "/Xcode/Developer"'])
    end

    it 'logs the command and streams stdout line by line' do
      stub_popen3(["Xcode 16.2\nBuild version 16C5032a\n", '', true])
      out, _err, error = capture_io { run_command('xcodebuild -version') }
      expect(error).to be_nil
      expect(out).to eq("@@[command] xcodebuild -version\nXcode 16.2\nBuild version 16C5032a\n")
    end

    it 'prints only the command log when the command succeeds silently' do
      stub_popen3(['', '', true])
      out, _err, _error = capture_io { run_command('true') }
      expect(out).to eq("@@[command] true\n")
    end

    it 'does not raise when a successful command writes to stderr' do
      stub_popen3(['ok', 'warning: something', true])
      expect { capture_io { run_command('xcodebuild -version') } }.not_to raise_error
    end
  end

  context 'negative path' do
    it 'raises RuntimeError with stderr when the command fails' do
      stub_popen3(['', 'xcode-select: error: invalid developer directory', false])
      expect { capture_io { run_command('sudo xcode-select --switch "/nope"') } }
        .to raise_error(RuntimeError, 'xcode-select: error: invalid developer directory')
    end

    it 'still prints stdout produced before the failure' do
      stub_popen3(["partial output\n", 'boom', false])
      old_out = $stdout
      $stdout = StringIO.new
      begin
        expect { run_command('xcodebuild -version') }.to raise_error(RuntimeError, 'boom')
        out = $stdout.string
      ensure
        $stdout = old_out
      end
      expect(out).to eq("@@[command] xcodebuild -version\npartial output\n")
    end

    it 'raises RuntimeError with an empty message when a failing command has empty stderr' do
      stub_popen3(['', '', false])
      expect { capture_io { run_command('false') } }.to raise_error(RuntimeError, '')
    end

    it 'propagates errors raised by Open3.popen3 (e.g. executable not found)' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'xcodebuild')
      expect { capture_io { run_command('xcodebuild -version') } }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'step execution' do
  let(:tmpdir)   { Dir.mktmpdir('xcode_select_step') }
  let(:env_file) { File.join(tmpdir, 'env_file') }
  let(:commands) { [] }
  let(:base_env) do
    {
      'AC_XCODE_LIST_DIR' => '/Applications/Xcode',
      'AC_XCODE_VERSION'  => '16.2',
      'AC_ENV_FILE_PATH'  => env_file
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path – /Applications/Xcode/ layout exists' do
    before do
      stub_xcode_root(true)
      stub_popen3(['', '', true], ["Xcode 16.2\nBuild version 16C5032a\n", '', true], recorder: commands)
    end

    it 'switches to <AC_XCODE_LIST_DIR>/<AC_XCODE_VERSION>/Xcode.app/Contents/Developer' do
      _out, _err, error = run_step(base_env)
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(0)
      expect(commands).to eq([
        'sudo xcode-select --switch "/Applications/Xcode/16.2/Xcode.app/Contents/Developer"',
        'xcodebuild -version'
      ])
    end

    it 'appends XCODE_DEVELOPER_DIR_PATH to AC_ENV_FILE_PATH' do
      File.write(env_file, "EXISTING=1\n")
      run_step(base_env)
      expect(File.read(env_file))
        .to eq("EXISTING=1\nXCODE_DEVELOPER_DIR_PATH=/Applications/Xcode/16.2/Xcode.app/Contents/Developer\n")
    end

    it 'prints the command logs and the xcodebuild version' do
      out, _err, _error = run_step(base_env)
      expect(out).to include('@@[command] sudo xcode-select --switch "/Applications/Xcode/16.2/Xcode.app/Contents/Developer"')
      expect(out).to include("@@[command] xcodebuild -version\nXcode 16.2\nBuild version 16C5032a\n")
    end

    it 'keeps a three-part version as-is in the path' do
      run_step(base_env.merge('AC_XCODE_VERSION' => '15.0.1'))
      expect(commands.first).to eq('sudo xcode-select --switch "/Applications/Xcode/15.0.1/Xcode.app/Contents/Developer"')
    end

    it 'quotes a list directory containing spaces' do
      run_step(base_env.merge('AC_XCODE_LIST_DIR' => '/Volumes/My Xcodes'))
      expect(commands.first).to eq('sudo xcode-select --switch "/Volumes/My Xcodes/16.2/Xcode.app/Contents/Developer"')
    end
  end

  context 'positive path – /Applications/Xcode/ layout missing (mounted volumes)' do
    before do
      stub_xcode_root(false)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'drops the last version component and uses /Volumes/xcode.<major.minor>' do
      run_step(base_env.merge('AC_XCODE_VERSION' => '16.2.1'))
      expect(commands.first).to eq('sudo xcode-select --switch "/Volumes/xcode.16.2/Xcode.app/Contents/Developer"')
      expect(File.read(env_file)).to eq("XCODE_DEVELOPER_DIR_PATH=/Volumes/xcode.16.2/Xcode.app/Contents/Developer\n")
    end

    it 'uses /Volumes/xcode.<major> for a two-part version' do
      run_step(base_env)
      expect(commands.first).to eq('sudo xcode-select --switch "/Volumes/xcode.16/Xcode.app/Contents/Developer"')
    end

    it 'ignores AC_XCODE_LIST_DIR' do
      run_step(base_env.merge('AC_XCODE_LIST_DIR' => '/somewhere/else'))
      expect(commands.first).not_to include('/somewhere/else')
    end

    it 'does not need AC_XCODE_LIST_DIR to be set' do
      _out, _err, error = run_step(base_env.reject { |k, _| k == 'AC_XCODE_LIST_DIR' })
      expect(error.status).to eq(0)
      expect(commands.first).to eq('sudo xcode-select --switch "/Volumes/xcode.16/Xcode.app/Contents/Developer"')
    end
  end

  context 'negative path – AC_XCODE_VERSION' do
    before do
      stub_xcode_root(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'aborts with "Missing AC_XCODE_VERSION." when missing, before running any command' do
      _out, err, error = run_step(base_env.reject { |k, _| k == 'AC_XCODE_VERSION' })
      expect(error.status).to eq(1)
      expect(err).to eq("Missing AC_XCODE_VERSION.\n")
      expect(commands).to be_empty
      expect(File.exist?(env_file)).to be(false)
    end

    it 'aborts with "Missing AC_XCODE_VERSION." when empty' do
      _out, err, error = run_step(base_env.merge('AC_XCODE_VERSION' => ''))
      expect(error.status).to eq(1)
      expect(err).to eq("Missing AC_XCODE_VERSION.\n")
      expect(commands).to be_empty
    end
  end

  context 'negative path – edge-case inputs (current behaviour pinned)' do
    before { stub_popen3(['', '', true], recorder: commands) }

    it 'builds a root-relative path when AC_XCODE_LIST_DIR is missing' do
      stub_xcode_root(true)
      run_step(base_env.reject { |k, _| k == 'AC_XCODE_LIST_DIR' })
      expect(commands.first).to eq('sudo xcode-select --switch "/16.2/Xcode.app/Contents/Developer"')
    end

    it 'builds a root-relative path when AC_XCODE_LIST_DIR is empty' do
      stub_xcode_root(true)
      run_step(base_env.merge('AC_XCODE_LIST_DIR' => ''))
      expect(commands.first).to eq('sudo xcode-select --switch "/16.2/Xcode.app/Contents/Developer"')
    end

    it 'produces "/Volumes/xcode." for a single-part version on mounted volumes' do
      stub_xcode_root(false)
      run_step(base_env.merge('AC_XCODE_VERSION' => '16'))
      expect(commands.first).to eq('sudo xcode-select --switch "/Volumes/xcode./Xcode.app/Contents/Developer"')
    end
  end

  context 'negative path – xcode-select fails' do
    before do
      stub_xcode_root(true)
      stub_popen3(['', 'xcode-select: error: invalid developer directory', false], recorder: commands)
    end

    it 'raises with the xcode-select error and stops' do
      expect { run_step(base_env) }
        .to raise_error(RuntimeError, 'xcode-select: error: invalid developer directory')
      expect(commands.size).to eq(1)
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'negative path – xcodebuild -version fails' do
    before do
      stub_xcode_root(true)
      stub_popen3(['', '', true], ['', 'xcodebuild: error: tool not found', false], recorder: commands)
    end

    it 'raises with the xcodebuild error and does not write the env file' do
      expect { run_step(base_env) }.to raise_error(RuntimeError, 'xcodebuild: error: tool not found')
      expect(commands).to eq([
        'sudo xcode-select --switch "/Applications/Xcode/16.2/Xcode.app/Contents/Developer"',
        'xcodebuild -version'
      ])
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'negative path – AC_ENV_FILE_PATH' do
    before do
      stub_xcode_root(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'raises TypeError when missing, after Xcode was already switched' do
      expect { run_step(base_env.reject { |k, _| k == 'AC_ENV_FILE_PATH' }) }
        .to raise_error(TypeError, /no implicit conversion of nil into String/)
      expect(commands.size).to eq(2)
    end

    it 'raises Errno::ENOENT when empty' do
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => '')) }.to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT when its directory does not exist' do
      missing = File.join(tmpdir, 'missing_dir', 'env_file')
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => missing)) }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  let(:tmpdir)   { Dir.mktmpdir('xcode_select_env') }
  let(:bin_dir)  { write_fake_tools(File.join(tmpdir, 'bin')) }
  let(:tool_log) { File.join(tmpdir, 'tool.log') }
  let(:env_file) { File.join(tmpdir, 'env_file') }
  let(:base_env) do
    {
      'PATH'              => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}",
      'FAKE_TOOL_LOG'     => tool_log,
      'AC_XCODE_LIST_DIR' => '/Applications/Xcode',
      'AC_XCODE_VERSION'  => '16.2'
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def tool_calls
    File.exist?(tool_log) ? File.read(tool_log).lines.map(&:chomp) : []
  end

  shared_examples 'aborts with message' do |env_override, expected_pattern|
    it "exits non-zero and stderr matches /#{expected_pattern.source}/" do
      env = instance_exec(&env_override)
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(expected_pattern)
    end
  end

  context 'required variable: AC_XCODE_VERSION' do
    context 'when missing' do
      include_examples 'aborts with message',
                       -> { base_env.reject { |k, _| k == 'AC_XCODE_VERSION' }.merge('AC_ENV_FILE_PATH' => env_file) },
                       /Missing AC_XCODE_VERSION\./
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       -> { base_env.merge('AC_XCODE_VERSION' => '', 'AC_ENV_FILE_PATH' => env_file) },
                       /Missing AC_XCODE_VERSION\./
    end

    it 'runs no command when it is missing' do
      run_main(base_env.reject { |k, _| k == 'AC_XCODE_VERSION' })
      expect(tool_calls).to be_empty
    end
  end

  context 'required variable: AC_ENV_FILE_PATH' do
    context 'when missing' do
      include_examples 'aborts with message', -> { base_env }, /no implicit conversion of nil into String/
    end

    context 'when an empty string' do
      include_examples 'aborts with message', -> { base_env.merge('AC_ENV_FILE_PATH' => '') },
                       /No such file or directory/
    end
  end

  context 'toolchain failures' do
    it 'exits non-zero with the xcode-select error and skips xcodebuild' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'FAKE_SUDO_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('xcode-select: error: invalid developer directory')
      expect(tool_calls.size).to eq(1)
      expect(File.exist?(env_file)).to be(false)
    end

    it 'exits non-zero with the xcodebuild error and does not write the env file' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'FAKE_XCODEBUILD_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('xcodebuild: error: tool not found')
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'all variables set' do
    let(:developer_dir) { expected_developer_dir('/Applications/Xcode', '16.2') }

    it 'switches Xcode, prints the version, writes XCODE_DEVELOPER_DIR_PATH and exits 0' do
      out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(tool_calls).to eq(["sudo xcode-select --switch #{developer_dir}", 'xcodebuild -version'])
      expect(out).to include("@@[command] sudo xcode-select --switch \"#{developer_dir}\"")
      expect(out).to include("Xcode 16.2\nBuild version 16C5032a")
      expect(File.read(env_file)).to eq("XCODE_DEVELOPER_DIR_PATH=#{developer_dir}\n")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'does not execute the step when required from another script' do
    out, err, status = Open3.capture3(STEP_ENV_KEYS.to_h { |k| [k, nil] },
                                      "ruby -e 'require %q(#{MAIN_RB}); puts :loaded'")
    expect(status.exitstatus).to eq(0)
    expect(err).to eq('')
    expect(out.strip).to eq('loaded')
  end

  it 'defines env_has_key and run_command' do
    expect(respond_to?(:env_has_key, true)).to be(true)
    expect(respond_to?(:run_command, true)).to be(true)
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = COVERAGE_SNAPSHOTS.reduce(result[main_path]) do |acc, snap|
    acc.zip(snap).map { |a, b| a.nil? ? nil : a + b.to_i }
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
