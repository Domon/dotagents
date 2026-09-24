# frozen_string_literal: true

require_relative "tidy_repo_helper"

class RecordTidyPassTest < Minitest::Test
  include TidyRepo

  SKILL_DIR = "/opt/agents/skills/tidy"
  OUTPUT = "**Interface — `Codec`:** `compress` (callers: `ScoreBenchmarkRun`)\n\n" \
           "**Removals:** none\n\n**Out of scope — flag separately:** none\n"

  def transcript(first_message)
    path = File.join(@state, "agent-#{rand(1_000_000)}.jsonl")
    lines = [{ "type" => "user", "message" => { "role" => "user", "content" => first_message } },
             { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "done" }] } }]
    File.write(path, lines.map { |line| JSON.generate(line) }.join("\n") + "\n")
    path
  end

  def tidy_prompt(args, skill_dir = SKILL_DIR)
    "Base directory for this skill: #{skill_dir}\n\n# Tidy\n\nReview: #{args}\n\n## Anti-taste\n"
  end

  def stop(transcript_path, message = OUTPUT)
    run_hook("record-tidy-pass.rb", "hook_event_name" => "SubagentStop", "session_id" => "s1", "agent_id" => "a1",
                                    "agent_transcript_path" => transcript_path, "last_assistant_message" => message)
  end

  def passes_in(root)
    dir = TidyPasses.for(root).dir
    Dir.exist?(dir) ? Dir.children(dir) : []
  end

  def test_records_a_commit_pass_from_the_arguments
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      assert_nil stop(transcript(tidy_prompt("#{root} git diff #{head}")))
      passes = TidyPasses.for(root)
      assert passes.pass_since?(head)
      record = JSON.parse(File.read(File.join(passes.dir, head)))
      assert_equal({ "args" => "#{root} git diff #{head}", "session_id" => "s1", "agent_id" => "a1" },
                   record.slice("args", "session_id", "agent_id"))
    end
  end

  def test_records_a_branch_pass_from_two_shas
    with_repo do |root|
      base = git!(root, "rev-parse", "HEAD")
      tip = commit(root, "app/models/codec.rb")
      stop(transcript(tidy_prompt("#{root} git diff #{base} #{tip}")))
      assert_equal [tip], TidyPasses.for(root).branch_tips(base)
    end
  end

  def test_records_a_pass_for_a_path_with_spaces
    with_repo("middle out") do |root|
      head = git!(root, "rev-parse", "HEAD")
      stop(transcript(tidy_prompt("#{root} git diff #{head}")))
      assert TidyPasses.for(root).pass_since?(head)
    end
  end

  def test_records_a_pass_for_a_quoted_path
    with_repo("middle out") do |root|
      base = git!(root, "rev-parse", "HEAD")
      tip = commit(root, "app/models/codec.rb")
      stop(transcript(tidy_prompt("\"#{root}\" git diff #{base} #{tip}")))
      assert_equal [tip], TidyPasses.for(root).branch_tips(base)
    end
  end

  def test_records_a_pass_for_a_path_through_a_symlink
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      link = File.join(@state, "linked-repo")
      File.symlink(root, link)
      stop(transcript(tidy_prompt("#{link} git diff #{head}")))
      assert TidyPasses.for(root).pass_since?(head)
    end
  end

  def test_records_nothing_for_another_skill
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      stop(transcript(tidy_prompt("#{root} git diff #{head}", "/opt/agents/skills/humane-review")))
      assert_empty passes_in(root)
    end
  end

  def test_records_nothing_for_files_pathspecs_or_a_subdirectory
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      FileUtils.mkdir_p(File.join(root, "app"))
      ["#{root} app/models/codec.rb", "#{root} git diff #{head} -- app", "#{root}/app git diff #{head}",
       "#{root} jj diff"].each do |args|
        stop(transcript(tidy_prompt(args)))
      end
      assert_empty passes_in(root)
    end
  end

  def test_records_nothing_when_the_output_lacks_the_closing_sections
    with_repo do |root|
      head = git!(root, "rev-parse", "HEAD")
      stop(transcript(tidy_prompt("#{root} git diff #{head}")), "I need permission to use Bash to complete this task.")
      assert_empty passes_in(root)
    end
  end

  def test_missing_transcript_and_malformed_input_are_ignored
    assert_nil stop(File.join(@state, "missing.jsonl"))
    assert_nil run_hook("record-tidy-pass.rb", "not json")
  end
end
