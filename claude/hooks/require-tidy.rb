#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "shellwords"
require File.join(File.dirname(File.realpath(__FILE__)), "lib", "tidy_passes")

module RequireTidy
  SEPARATORS = /&&|\|\||;|\n|\|/
  HEREDOC = /(<<-?\s*(['"]?)(\w+)\2)[^\n]*\n.*?^\s*\3[ \t]*$/m
  ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
  GENERATED = %r{(\A|/)db/([^/]+_)?schema\.rb\z}
  BASE_REFS = %w[origin/HEAD origin/main origin/master main master].freeze
  COMMIT_VALUE_OPTIONS = %w[-m --message -F --file -C --reuse-message -c --reedit-message --fixup --squash
                            --author --date -t --template --trailer --cleanup --pathspec-from-file].freeze
  SHORT_VALUE_FLAGS = "mFCctSu"
  SHORT_NEXT_VALUE_FLAGS = "mFCct"
  TRUNKS = %w[main master].freeze
  UNGATED_PUSHES = %w[--delete -d --tags --mirror].freeze

  GitCall = Struct.new(:dir, :subcommand, :args) do
    def operands = args.reject { |arg| arg.start_with?("-") }
  end

  Verdict = Struct.new(:kind, :repo, :sha, :tidy_command, :message) do
    def deny? = !message.nil?

    def log(ids)
      TidyPasses.log_event(deny? ? "deny" : "allow",
                           { "kind" => kind, "repo" => repo, "sha" => sha, "tidy_command" => tidy_command }.merge(ids))
    end
  end

  module_function

  def verdicts(command, cwd)
    return [] unless command.include?("git")

    adds = []
    found = []
    git_calls(command, cwd).each do |call|
      adds << call if call.subcommand == "add"
      verdict = case call.subcommand
                when "commit" then commit_verdict(call, adds)
                when "push" then push_verdict(call)
                end
      next unless verdict

      found << verdict
      break if verdict.deny?
    end
    found
  end

  def git_calls(command, cwd)
    dir = cwd
    command.gsub(HEREDOC, '\1').split(SEPARATORS).filter_map do |segment|
      words = split_words(segment)
      words.shift while words.first&.match?(ASSIGNMENT)
      case words.first
      when "cd"
        dir = File.expand_path(words[1] || "~", dir)
        nil
      when "git"
        git_call(words.drop(1), dir)
      end
    end
  end

  def split_words(segment)
    Shellwords.split(segment)
  rescue ArgumentError
    segment.split
  end

  def git_call(words, dir)
    while words.first&.start_with?("-")
      option = words.shift
      dir = File.expand_path(words.shift.to_s, dir) if option == "-C"
      words.shift if option == "-c"
    end
    GitCall.new(dir, words.first, words.drop(1))
  end

  def commit_verdict(call, adds)
    passes = TidyPasses.for(call.dir) or return
    root = passes.toplevel
    head = git(root, "rev-parse", "--verify", "--quiet", "HEAD") or return
    committing = changed_files(root, *commit_scope(call, root))
    new_files = ruby_files(adds.flat_map { |add| untracked_files(add, root) })
    tracked = adds.flat_map { |add| changed_files(root, "HEAD", "--", *add_paths(add, root)) }
    return if new_files.empty? && ruby_files(committing + tracked).empty?

    allowed = Verdict.new(kind: "commit", repo: root, sha: head)
    return allowed if passes.pass_since?(head)

    parent = git(root, "rev-parse", "--verify", "--quiet", "HEAD^") if call.args.include?("--amend")
    committed_at = git(root, "log", "-1", "--format=%ct", "HEAD").to_i if parent
    return allowed if parent && passes.pass_since?(parent, recorded_after: committed_at)

    tidy_command = "/tidy #{root} git diff #{parent || head}"
    staging = "Stage the new files first: `#{Shellwords.join(['git', '-C', root, 'add', *new_files])}`. " unless new_files.empty?
    Verdict.new(kind: "commit", repo: root, sha: head, tidy_command:,
                message: "This commit has Ruby that /tidy hasn't reviewed. #{staging}" \
                         "Run `#{tidy_command}`, apply the sketches you accept, then commit again.")
  end

  def commit_scope(call, root)
    all = false
    paths = []
    args = call.args.dup
    while (arg = args.shift)
      if arg == "--"
        paths.concat(args.map { |path| relative_path(path, call.dir, root) })
        break
      elsif COMMIT_VALUE_OPTIONS.include?(arg)
        args.shift
      elsif arg == "--all"
        all = true
      elsif arg.match?(/\A-[^-]/)
        cluster_all, takes_next = short_flags(arg)
        all ||= cluster_all
        args.shift if takes_next
      elsif !arg.start_with?("-") && File.exist?(File.expand_path(arg, call.dir))
        paths << relative_path(arg, call.dir, root)
      end
    end
    return ["HEAD", "--", *paths] unless paths.empty?

    all ? ["HEAD"] : ["--cached"]
  end

  def short_flags(cluster)
    letters = cluster[1..]
    letters.each_char.with_index do |letter, index|
      return [true, false] if letter == "a"
      next unless SHORT_VALUE_FLAGS.include?(letter)

      return [false, index == letters.length - 1 && SHORT_NEXT_VALUE_FLAGS.include?(letter)]
    end
    [false, false]
  end

  def relative_path(path, dir, root)
    full = File.expand_path(path, dir)
    return path unless File.exist?(full)

    Pathname.new(File.realpath(full)).relative_path_from(Pathname.new(root)).to_s
  end

  def push_verdict(call)
    return if call.args.any? { |arg| UNGATED_PUSHES.include?(arg) }

    passes = TidyPasses.for(call.dir) or return
    root = passes.toplevel
    source, destination = push_refs(call, root)
    return if source.nil? || TRUNKS.include?(destination)

    tip = passes.commit_sha(source) or return
    base_ref = BASE_REFS.find { |ref| git(root, "rev-parse", "--verify", "--quiet", ref) } or return
    base = git(root, "merge-base", base_ref, tip) or return
    return if ruby_files(git_lines(root, "diff", "--name-only", base, tip)).empty?
    reviewed = passes.branch_tips(base).any? { |pass_tip| pass_tip == tip || ancestor?(root, pass_tip, tip) }
    return Verdict.new(kind: "push", repo: root, sha: tip) if reviewed

    tidy_command = "/tidy #{root} git diff #{base} #{tip}"
    Verdict.new(kind: "push", repo: root, sha: tip, tidy_command:,
                message: "Pushing #{destination} needs a whole-branch /tidy pass. Run `#{tidy_command}`, " \
                         "apply the sketches you accept, commit, then push again.")
  end

  def push_refs(call, root)
    refspec = call.operands[1]
    return [nil, nil] if refspec&.start_with?(":")

    source, destination = refspec.to_s.delete_prefix("+").split(":", 2)
    source = git(root, "rev-parse", "--abbrev-ref", "HEAD") if source.to_s.empty?
    [source, (destination || source).to_s.delete_prefix("refs/heads/")]
  end

  def untracked_files(add, root)
    git_lines(root, "ls-files", "--others", "--exclude-standard", "--", *add_paths(add, root))
  end

  def add_paths(add, root)
    paths = add.operands.map { |path| relative_path(path, add.dir, root) }
    paths.empty? ? ["."] : paths
  end

  def changed_files(root, *scope)
    git_lines(root, "diff", "--name-only", "--diff-filter=ACMR", *scope)
  end

  def ruby_files(names)
    names.select { |name| name.end_with?(".rb") && !name.match?(GENERATED) }
  end

  def git_lines(root, *args)
    git(root, *args).to_s.split("\n")
  end

  def ancestor?(root, ancestor, descendant)
    system("git", "-C", root, "merge-base", "--is-ancestor", ancestor, descendant, out: File::NULL, err: File::NULL)
  end

  def git(root, *args)
    out, _err, status = Open3.capture3("git", "-C", root, *args)
    status.success? ? out.chomp : nil
  end

  def skip_note(session_id, repo)
    skip = TidyPasses.skip_since_last_pass(session_id, repo) or return
    opening = "Your last /tidy run here did not count"
    return "#{opening}: it ended without its Removals and Out of scope sections." if skip["reason"] == TidyPasses::MISSING_SECTIONS

    "#{opening} (#{skip['reason']}): it was given `#{skip['args'].delete('`')}`."
  # A failing note must not cost the caller its denial.
  rescue StandardError
    nil
  end

  def deny(reason)
    JSON.generate("hookSpecificOutput" => { "hookEventName" => "PreToolUse", "permissionDecision" => "deny",
                                            "permissionDecisionReason" => reason })
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    input = JSON.parse($stdin.read)
    verdicts = RequireTidy.verdicts(input.dig("tool_input", "command").to_s, input["cwd"].to_s)
    verdicts.each { |verdict| verdict.log(input.slice("session_id", "agent_id")) }
    denial = verdicts.find(&:deny?)
    if denial
      reason = [denial.message, RequireTidy.skip_note(input["session_id"], denial.repo)].compact.join(" ")
      puts RequireTidy.deny(reason)
    end
  rescue StandardError => e
    TidyPasses.log_error("require-tidy", e)
  end
  exit 0
end
