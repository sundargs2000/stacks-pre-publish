const core = require('@actions/core');
const github = require('@actions/github');

async function run() {
    console.log(github.context);
}

run();

