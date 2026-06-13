# shellcheck shell=bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329 # ShellSpec DSL invokes functions indirectly

Describe 'bin/profile-installer.js'
  # SHELLSPEC_PROJECT_ROOT is the dir containing .shellspec (the repo root).
  installer="${SHELLSPEC_PROJECT_ROOT}/bin/profile-installer.js"

  run_installer() {
    node "$installer" "$@"
  }

  Describe 'single bundled profile'
    It 'loads base and emits an env block'
      When run run_installer base
      The status should be success
      The output should include 'PROFILE_ENV'
      The output should include 'PROFILE_IMAGE_TAG=profile-'
      The output should include 'PROFILE_COMPOSITION_HASH='
    End
  End

  Describe 'composition'
    It 'composes base + mirror to PROFILE_MODE=mirror'
      When run run_installer base mirror
      The status should be success
      The output should include 'PROFILE_MODE=mirror'
    End

    It 'composes base + docker to PROFILE_CAPABILITIES=docker'
      When run run_installer base docker
      The status should be success
      The output should include 'PROFILE_CAPABILITIES=docker'
    End

    It 'errors on conflicting mode scalars (mirror + static)'
      When run run_installer mirror static
      The status should be failure
      The stderr should include 'scalar conflict'
      The stderr should include 'mode'
    End
  End

  Describe 'discovery errors'
    It 'exits nonzero for a missing profile name'
      When run run_installer no-such-profile
      The status should be failure
      The stderr should include 'not found'
    End

    It 'exits nonzero for a name containing a path separator'
      When run run_installer bad/name
      The status should be failure
      The stderr should include 'path separator'
    End
  End

  Describe '--mode override'
    It 'applies even when no composed profile sets mode'
      When run run_installer --output env --mode static base
      The status should be success
      The output should include 'PROFILE_MODE=static'
    End
  End

  Describe 'JSON output'
    It 'emits a single-line JSON block that parses'
      validate_json() {
        node "$installer" --output json base docker \
          | node -e "JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write('JSON_OK')"
      }
      When call validate_json
      The status should be success
      The output should equal 'JSON_OK'
    End
  End

  Describe 'composition-hash stability'
    It 'produces the same hash across runs for the same composition'
      hash_twice() {
        h1=$(node "$installer" --output env base docker | grep PROFILE_COMPOSITION_HASH)
        h2=$(node "$installer" --output env base docker | grep PROFILE_COMPOSITION_HASH)
        [ "$h1" = "$h2" ] && printf '%s' "$h1"
      }
      When call hash_twice
      The status should be success
      The output should include 'PROFILE_COMPOSITION_HASH='
    End
  End

  Describe 'marketplaces field'
    # Run installer from test/fixtures so fixture profiles are found via ./profiles/.
    fixtures="${SHELLSPEC_PROJECT_ROOT}/test/fixtures"

    It 'parses and emits a https:// marketplace entry in JSON output'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json mp-https
      }
      When call run_from_fixtures
      The status should be success
      The output should include '"marketplaces"'
      The output should include 'registry.example.com'
    End

    It 'accepts a file:// marketplace entry'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json mp-file
      }
      When call run_from_fixtures
      The status should be success
      The output should include '"marketplaces"'
      The output should include 'file://'
    End

    It 'rejects a marketplace entry that does not start with https:// or file://'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json mp-bad
      }
      When run run_from_fixtures
      The status should be failure
      The stderr should include 'must start with https:// or file://'
    End

    It 'defaults marketplaces to [] when absent from the profile'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json eap-absent
      }
      When call run_from_fixtures
      The status should be success
      The output should include '"marketplaces":[]'
    End

    It 'unions marketplaces from two profiles with no duplicates'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json mp-two-entries mp-two-entries-b
      }
      When call run_from_fixtures
      The status should be success
      The output should include 'registry-a.example.com'
      The output should include 'registry-b.example.com'
    End

    It 'deduplicates identical marketplace entries across profiles'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json mp-two-entries mp-dup \
          | node -e "
            const d = JSON.parse(require('fs').readFileSync(0,'utf8'));
            const count = d.marketplaces.filter(m => m === 'https://registry-a.example.com/plugins').length;
            process.stdout.write(String(count));
          "
      }
      When call run_from_fixtures
      The status should be success
      The output should equal '1'
    End
  End

  Describe 'enable_all_plugins field'
    fixtures="${SHELLSPEC_PROJECT_ROOT}/test/fixtures"

    It 'ORs enable_all_plugins: true from one profile into a two-profile composition'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json eap-true eap-false \
          | node -e "
            const d = JSON.parse(require('fs').readFileSync(0,'utf8'));
            process.stdout.write(String(d.enable_all_plugins));
          "
      }
      When call run_from_fixtures
      The status should be success
      The output should equal 'true'
    End

    It 'ORs enable_all_plugins: false from both profiles to false'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json eap-false eap-absent \
          | node -e "
            const d = JSON.parse(require('fs').readFileSync(0,'utf8'));
            process.stdout.write(String(d.enable_all_plugins));
          "
      }
      When call run_from_fixtures
      The status should be success
      The output should equal 'false'
    End

    It 'defaults enable_all_plugins to false when absent from the profile'
      run_from_fixtures() {
        cd "$fixtures" && node "$installer" --output json eap-absent \
          | node -e "
            const d = JSON.parse(require('fs').readFileSync(0,'utf8'));
            process.stdout.write(String(d.enable_all_plugins));
          "
      }
      When call run_from_fixtures
      The status should be success
      The output should equal 'false'
    End
  End
End
