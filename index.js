const core = require('@actions/core');
const fs = require('fs'); 
const { execSync } = require('child_process');

function run() {
    const templatePath = getFilePath('stack');
    
    if (!templatePath) {
        core.setFailed('Template empty or not present.');
        return;
    }

    const valuesPath = getFilePath('values') || "";

    if (valuesPath != "") {
        core.debug('values file found.');
    }

    console.log(execSync('ls').toString());

    console.log("supbron\n", execSync('cd .. && ls').toString());
    try {
        execSync(`ruby ./validator.rb ${templatePath} ${valuesPath}`);
    } catch (error) {
        core.setFailed('Something failed. Probably not your fault.');
        core.debug(error.toString());
        return;
    }
    
    core.debug("Checks finished");

    errors = fs.readFileSync('pre_publish_validate.errors.log').toString();

    if (errors == "") {
        core.info("Pre publish checks passed ✅ You are good for a release.");
        
        core.setOutput("success", true);
        core.setOutput("errors", "");
    } else {
        core.info("Pre publish checks failed ❌ Errors found:");
        core.info(errors);

        core.setOutput("success", false);
        core.setOutput("errors", errors);
    }
}

function getFilePath(fileName) {
    if (fs.existsSync(`.github/stacks/${fileName}.yml`)) {
        return `.github/stacks/${fileName}.yml`
    } else if (fs.existsSync(`.github/stacks/${fileName}.yaml`)) {
        return `.github/stacks/${fileName}.yaml`
    } else return undefined;
}

run();
