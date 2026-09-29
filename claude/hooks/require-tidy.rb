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

  module_function

  def reason(command, cwd)
    return nil unless command.include?("git")

    adds = []
    git_calls(command, cwd).each do |call|
      adds << call if call.subcommand == "add"
      found = case call.subcommand
              when "commit" then commit_reason(call, adds)
              when "push" then push_reason(call)
              end
      return found if found
    end
    nil
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

  def commit_reason(call, adds)
    passes = TidyPasses.for(call.dir) or return
    root = passes.toplevel
    head = git(root, "rev-parse", "--verify", "--quiet", "HEAD") or return
    committing = changed_files(root, *commit_scope(call, root))
    new_files = ruby_files(adds.flat_map { |add| untracked_files(add, root) })
    tracked = adds.flat_map { |add| changed_files(root, "HEAD", "--", *add_paths(add, root)) }
    return if new_files.empty? && ruby_files(committing + tracked).empty?
    return if passes.pass_since?(head)

    parent = git(root, "rev-parse", "--verify", "--quiet", "HEAD^") if call.args.include?("--amend")
    committed_at = git(root, "log", "-1", "--format=%ct", "HEAD").to_i if parent
    return if parent && passes.pass_since?(parent, recorded_after: committed_at)

    staging = "Stage the new files first: `#{Shellwords.join(['git', '-C', root, 'add', *new_files])}`. " unless new_files.empty?
    "This commit has Ruby that /tidy hasn't reviewed. #{staging}Run `/tidy #{root} git diff #{parent || head}`, " \
      "apply the sketches you accept, then commit again."
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

  def push_reason(call)
    return if call.args.any? { |arg| UNGATED_PUSHES.include?(arg) }

    passes = TidyPasses.for(call.dir) or return
    root = passes.toplevel
    source, destination = push_refs(call, root)
    return if source.nil? || TRUNKS.include?(destination)

    tip = git(root, "rev-parse", "--verify", "--quiet", "#{source}^{commit}") or return
    base_ref = BASE_REFS.find { |ref| git(root, "rev-parse", "--verify", "--quiet", ref) } or return
    base = git(root, "merge-base", base_ref, tip) or return
    return if ruby_files(git_lines(root, "diff", "--name-only", base, tip)).empty?
    return if passes.branch_tips(base).any? { |pass_tip| pass_tip == tip || ancestor?(root, pass_tip, tip) }

    "Pushing #{destination} needs a whole-branch /tidy pass. Run `/tidy #{root} git diff #{base} #{tip}`, " \
      "apply the sketches you accept, commit, then push again."
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

  def deny(reason)
    JSON.generate("hookSpecificOutput" => { "hookEventName" => "PreToolUse", "permissionDecision" => "deny",
                                            "permissionDecisionReason" => reason })
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    input = JSON.parse($stdin.read)
    found = RequireTidy.reason(input.dig("tool_input", "command").to_s, input["cwd"].to_s)
    puts RequireTidy.deny(found) if found
  rescue StandardError => e
    TidyPasses.log("require-tidy #{e.class}: #{e.message}")
  end
  exit 0
end
