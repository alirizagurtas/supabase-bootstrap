Describe 'supabase-update.sh'
  Include ./supabase-update.sh

  It 'can be sourced without running main'
    When call type main
    The status should be success
    The output should include 'main is a function'
  End

  It 'exposes argument parsing'
    When call type parse_args
    The status should be success
    The output should include 'parse_args is a function'
  End
End
