<div align="center">
  <img align="center" width="250" src="assets/logos/jfrog-orb-256px.png" alt="JFrog Orb">
  <h1>CircleCI JFrog Orb</h1>
  <i>A CircleCI orb for streamlining JFrog CLI intallation and use.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/jfrog-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/jfrog-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/jfrog-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/jfrog-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/jfrog-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This unofficial JFrog CLI orb facilitates the installation and execution of the JFrog CLI tool (`jf`) within CircleCI pipelines. An official JFrog Artifactory orb can be found at: [jfrog/artifactory-orb](https://circleci.com/developer/orbs/orb/jfrog/artifactory-orb). This one differs in its ability to provide version locking of the `jf` tool, providing more stable and consistent CI environment that won't break on a Friday night. This avoids install scripts that greedily fetch the latest version every time.
