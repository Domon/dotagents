# frozen_string_literal: true

require_relative "ban_words_helper"

class BashArmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def blocked?(cmd)
    !BanWords.blocked_words("Bash", { "command" => cmd }).empty?
  end

  def write_temp(text)
    path = File.join(@dir, "body-#{rand(1_000_000)}.md")
    File.write(path, "#{text}\n")
    path
  end

  def test_git_commit_carrying_a_banned_word_is_blocked
    assert blocked?(%(git commit -m "#{FLAGGED}"))
  end

  def test_gh_pr_create_carrying_a_banned_word_is_blocked
    assert blocked?(%(gh pr create --body "#{FLAGGED}"))
  end

  def test_clean_git_commit_passes
    refute blocked?(%(git commit -m "#{CLEAN}"))
  end

  def test_review_comment_reply_is_scanned
    assert blocked?(%(gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST -F in_reply_to=123 -f body="#{FLAGGED}"))
  end

  def test_issue_comment_is_scanned
    assert blocked?(%(gh api repos/pied-piper/middle-out/issues/4242/comments -f body="#{FLAGGED}"))
  end

  def test_gh_pr_comment_subcommand_is_scanned
    assert blocked?(%(gh pr comment 4242 --body "#{FLAGGED}"))
  end

  def test_gh_pr_review_is_scanned
    assert blocked?(%(gh pr review 4242 --comment --body "#{FLAGGED}"))
  end

  def test_patch_of_a_pr_body_is_scanned
    assert blocked?(%(gh api repos/pied-piper/middle-out/pulls/4242 -X PATCH -f body="#{FLAGGED}"))
  end

  def test_clean_comment_body_passes
    refute blocked?(%(gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST -F in_reply_to=123 -f body="#{CLEAN}"))
  end

  def test_body_from_a_file_is_resolved_and_scanned
    path = write_temp("This reply mentions #{FLAGGED}.")
    assert blocked?("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST -F body=@#{path}")
  end

  def test_clean_body_from_a_file_passes
    path = write_temp(CLEAN)
    refute blocked?("gh api repos/pied-piper/middle-out/pulls/4242/comments -X POST -F body=@#{path}")
  end

  def test_lowercase_f_flag_with_a_file_is_also_resolved
    path = write_temp("This reply mentions #{FLAGGED}.")
    assert blocked?("gh api repos/pied-piper/middle-out/issues/4242/comments -f body=@#{path}")
  end

  def test_a_missing_body_file_does_not_raise
    refute blocked?("gh api repos/pied-piper/middle-out/pulls/4242/comments -F body=@/nonexistent/nowhere.md")
  end

  def test_git_commit_message_from_a_file_is_scanned
    path = write_temp(FLAGGED)
    assert blocked?("git commit -F #{path}")
    assert blocked?("git commit --file #{path}")
  end

  def test_gh_pr_body_file_is_scanned
    path = write_temp(FLAGGED)
    assert blocked?("gh pr create --title t --body-file #{path}")
  end

  def test_gh_api_input_file_is_scanned
    path = write_temp(%({"body": "#{FLAGGED}"}))
    assert blocked?("gh api repos/pied-piper/middle-out/pulls/4242 --method PATCH --input #{path}")
  end

  def test_gh_api_long_method_flag_counts_as_a_write
    assert blocked?(%(gh api repos/pied-piper/middle-out/issues/4242/comments --method POST -f body="#{FLAGGED}"))
  end

  def test_clean_body_file_passes
    path = write_temp(CLEAN)
    refute blocked?("gh pr create --title t --body-file #{path}")
  end

  def test_reading_a_pr_body_is_not_scanned
    refute blocked?("gh api repos/pied-piper/middle-out/pulls/4242 --jq .body")
  end

  def test_searching_for_a_banned_word_is_not_scanned
    refute blocked?(%(grep -rn "#{FLAGGED}" app/))
  end
end
