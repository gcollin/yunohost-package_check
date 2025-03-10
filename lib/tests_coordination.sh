#!/bin/bash

source lib/lxc.sh
source lib/tests.sh
source lib/witness.sh
source lib/legacy.sh

readonly complete_log="./Complete-${WORKER_ID}.log"

# Purge some log files
rm -f "$complete_log" && touch "$complete_log"

# Redirect fd 3 (=debug steam) to complete log
exec 3>>$complete_log

#=================================================
# Misc test helpers & coordination
#=================================================

run_all_tests() {

    mkdir -p $TEST_CONTEXT/tests
    mkdir -p $TEST_CONTEXT/results
    mkdir -p $TEST_CONTEXT/logs

    if [ -e $package_path/manifest.json ]
    then
        readonly app_id="$(jq -r .id $package_path/manifest.json)"
    else
        readonly app_id="$(grep '^id = ' $package_path/manifest.toml | tr -d '" ' | awk -F= '{print $2}')"
    fi

    tests_toml="$package_path/tests.toml"
    if [ -e "$tests_toml" ]
    then
        python3 "./lib/parse_tests_toml.py" "$package_path" "$TEST_CONTEXT/tests"
    else
        # Parse the check_process only if it's exist
        check_process="$package_path/check_process"

        [ -e "$check_process" ] \
            && parse_check_process \
            || guess_test_configuration
    fi

    # Start the timer for this test
    start_timer
    # And keep this value separately
    complete_start_timer=$starttime

    # Break after the first tests serie
    if [ $interactive -eq 1 ]; then
        read -p "Press a key to start the tests..." < /dev/tty
    fi

    # Launch all tests successively
    cat $TEST_CONTEXT/tests/*.json >> /proc/self/fd/3

    # Reset and create a fresh container to work with
    check_lxd_setup
    LXC_RESET
    LXC_CREATE
    # Be sure that the container is running
    LXC_EXEC "true"

    # Print the version of YunoHost from the LXC container
    log_small_title "YunoHost versions"
    LXC_EXEC "yunohost --version"
    LXC_EXEC "yunohost --version --output-as json" | jq -r .yunohost.version >> $TEST_CONTEXT/ynh_version
    LXC_EXEC "yunohost --version --output-as json" | jq -r .yunohost.repo >> $TEST_CONTEXT/ynh_branch
    echo $ARCH > $TEST_CONTEXT/architecture
    echo $app_id > $TEST_CONTEXT/app_id

    # Init the value for the current test
    current_test_number=1

    # The list of test contains for example "TEST_UPGRADE some_commit_id
    for testfile in "$TEST_CONTEXT"/tests/*.json;
    do
        TEST_LAUNCHER $testfile
        current_test_number=$((current_test_number+1))
    done

    # Print the final results of the tests
    log_title "Tests summary"

    python3 lib/analyze_test_results.py $TEST_CONTEXT 2> ./results-${WORKER_ID}.json
    [[ -e "$TEST_CONTEXT/summary.png" ]] && cp "$TEST_CONTEXT/summary.png" ./summary.png || rm -f summary.png

    # Restore the started time for the timer
    starttime=$complete_start_timer
    # End the timer for the test
    stop_timer all_tests

    echo "You can find the complete log of these tests in $(realpath $complete_log)"

}

TEST_LAUNCHER () {
    local testfile="$1"

    # Start the timer for this test
    start_timer
    # And keep this value separately
    local global_start_timer=$starttime

    current_test_id=$(basename $testfile | cut -d. -f1)
    current_test_infos="$TEST_CONTEXT/tests/$current_test_id.json"
    current_test_results="$TEST_CONTEXT/results/$current_test_id.json"
    current_test_log="$TEST_CONTEXT/logs/$current_test_id.log"
    echo "{}" > $current_test_results
    echo "" > $current_test_log

    local test_type=$(jq -r '.test_type' $testfile)
    local test_arg=$(jq -r '.test_arg' $testfile)

    # Execute the test
    $test_type $test_arg

    local test_result=$?

    [ $test_result -eq 0 ] && SET_RESULT "success" main_result || SET_RESULT "failure" main_result

    # Check that we don't have this message characteristic of a file that got manually modified,
    # which should not happen during tests because no human modified the file ...
    if grep -q --extended-regexp 'has been manually modified since the installation or last upgrade. So it has been duplicated' $current_test_log
    then
        log_error "Apparently the log is telling that 'some file got manually modified' ... which should not happen, considering that no human modified the file ... ! Maybe you need to check what's happening with ynh_store_file_checksum and ynh_backup_if_checksum_is_different between install and upgrade."
    fi

    # Check that the number of warning ain't higher than a treshold
    local n_warnings=$(grep --extended-regexp '^[0-9]+\s+.{1,15}WARNING' $current_test_log | wc -l)
    # (we ignore this test for upgrade from older commits to avoid having to patch older commits for this)
    if [ "$n_warnings" -gt 50 ] && [ "$test_type" != "TEST_UPGRADE" -o "$test_arg" == "" ]
    then
        if [ "$n_warnings" -gt 200 ]
        then
            log_error "There's A SHITLOAD of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
            log_report_test_failed
            SET_RESULT "failure" too_many_warnings
        else
            log_error "There's quite a lot of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
        fi
    fi

    local test_duration=$(echo $(( $(date +%s) - $global_start_timer )))
    SET_RESULT "$test_duration" test_duration

    break_before_continue

    # Restore the started time for the timer
    starttime=$global_start_timer
    # End the timer for the test
    stop_timer one_test

    LXC_STOP $LXC_NAME

    # Update the lock file with the date of the last finished test.
    # $$ is the PID of package_check itself.
    echo "$1 $2:$(date +%s):$$" > "$lock_file"
}

SET_RESULT() {
    local result=$1
    local name=$2
    if [ "$name" != "test_duration" ]
    then
        [ "$result" == "success" ] && log_report_test_success || log_report_test_failed
    fi
    local current_results="$(cat $current_test_results)"
    echo "$current_results" | jq --arg result $result ".$name=\$result" > $current_test_results
}

#=================================================

at_least_one_install_succeeded () {

    for TEST in "$TEST_CONTEXT"/tests/*.json
    do
        local test_id=$(basename $TEST | cut -d. -f1)
        jq -e '. | select(.test_type == "TEST_INSTALL")' $TEST >/dev/null \
        && jq -e '. | select(.main_result == "success")' $TEST_CONTEXT/results/$test_id.json >/dev/null \
        && return 0
    done

    log_error "All installs failed, therefore the following tests cannot be performed..."
    return 1
}

break_before_continue () {

    if [ $interactive -eq 1 ] || [ $interactive_on_errors -eq 1 ] && [ ! $test_result -eq 0 ]
    then
        echo "To enter a shell on the lxc:"
        echo "     lxc exec $LXC_NAME bash"
        read -p "Press a key to delete the application and continue...." < /dev/tty
    fi
}

start_test () {

    local current_test_serie=$(jq -r '.test_serie' $testfile)
    [[ "$current_test_serie" != "default" ]] \
        && current_test_serie="($current_test_serie) " \
        || current_test_serie=""

    total_number_of_test=$(ls $TEST_CONTEXT/tests/*.json | wc -l)

    log_title " [Test $current_test_number/$total_number_of_test] $current_test_serie$1"
}

there_is_an_install_type() {
    local install_type=$1

    for TEST in $TEST_CONTEXT/tests/*.json
    do
        jq --arg install_type "$install_type" -e '. | select(.test_type == "TEST_INSTALL") | select(.test_arg == $install_type)' $TEST > /dev/null \
        && return 0
    done

    return 1
}

there_is_a_root_install_test() {
    return $(there_is_an_install_type "root")
}

there_is_a_subdir_install_test() {
    return $(there_is_an_install_type "subdir")
}

this_is_a_web_app () {
    # An app is considered to be a webapp if there is a root or a subdir test
    return $(there_is_a_root_install_test) || $(there_is_a_subdir_install_test)
}

root_path () {
    echo "/"
}

subdir_path () {
    echo "/path"
}

default_install_path() {
    # All webapps should be installable at the root or in a subpath of a domain
    there_is_a_root_install_test && { root_path; return; }
    there_is_a_subdir_install_test && { subdir_path; return; }
    echo ""
}

path_to_install_type() {
    local check_path="$1"

    [ -z "$check_path" ] && { echo "nourl"; return; }
    [ "$check_path" == "/" ] && { echo "root"; return; }
    echo "subdir"
}
