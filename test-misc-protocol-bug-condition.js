#!/usr/bin/env node

/**
 * Bug Condition Exploration Test for Misc Protocol Test Failures
 * 
 * **Validates: Requirements 2.1, 2.2**
 * 
 * This test MUST FAIL on unfixed code - failure confirms the bug exists.
 * DO NOT attempt to fix the test or the code when it fails.
 * 
 * GOAL: Surface counterexamples that demonstrate the bug exists
 * - Test Docker build process for js-v3.x implementation
 * - Test dependency resolution in js-v3.x directory  
 * - Test misc test matrix generation with js-v3.x included
 * - Test misc protocol execution with js-v3.x excluded (should show only 1 passing test)
 * 
 * EXPECTED OUTCOME: Test FAILS (this is correct - it proves the bug exists)
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

// Test configuration
const JS_V3X_PATH = 'misc/images/js/v3.x';
const MISC_PATH = 'misc';
const TEST_TIMEOUT = 300000; // 5 minutes

class BugConditionExplorer {
  constructor() {
    this.counterexamples = [];
    this.testResults = {
      dockerBuildFailed: false,
      dependencyResolutionFailed: false,
      testMatrixGenerationFailed: false,
      limitedTestCoverage: false,
      errorMessages: []
    };
  }

  log(message) {
    console.log(`[BUG-EXPLORATION] ${message}`);
  }

  error(message) {
    console.error(`[BUG-EXPLORATION ERROR] ${message}`);
  }

  addCounterexample(type, description, details) {
    const counterexample = {
      type,
      description,
      details,
      timestamp: new Date().toISOString()
    };
    this.counterexamples.push(counterexample);
    this.log(`COUNTEREXAMPLE [${type}]: ${description}`);
    if (details) {
      this.log(`Details: ${JSON.stringify(details, null, 2)}`);
    }
  }

  /**
   * Test 1: Docker Build Process for js-v3.x Implementation
   * Expected to FAIL on unfixed code due to dependency conflicts
   */
  async testDockerBuild() {
    this.log('Testing Docker build process for js-v3.x implementation...');
    
    try {
      // Change to js-v3.x directory
      process.chdir(JS_V3X_PATH);
      
      // Attempt Docker build
      const buildCommand = 'docker build -t misc-js-v3x-test .';
      this.log(`Executing: ${buildCommand}`);
      
      const result = execSync(buildCommand, { 
        encoding: 'utf8', 
        timeout: TEST_TIMEOUT,
        stdio: 'pipe'
      });
      
      this.log('Docker build completed successfully');
      this.log(`Build output: ${result}`);
      
      // If we get here, the build succeeded (unexpected for unfixed code)
      return false;
      
    } catch (error) {
      // This is expected for unfixed code
      this.testResults.dockerBuildFailed = true;
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'DOCKER_BUILD_FAILURE',
        'js-v3.x Docker image build failed',
        {
          command: 'docker build -t misc-js-v3x-test .',
          exitCode: error.status,
          stderr: error.stderr?.toString(),
          stdout: error.stdout?.toString()
        }
      );
      
      return true; // Expected failure
    } finally {
      // Return to original directory
      process.chdir('../../..');
    }
  }

  /**
   * Test 2: Dependency Resolution in js-v3.x Directory
   * Expected to FAIL on unfixed code due to libp2p v3.0.3 compatibility issues
   */
  async testDependencyResolution() {
    this.log('Testing dependency resolution in js-v3.x directory...');
    
    try {
      // Change to js-v3.x directory
      process.chdir(JS_V3X_PATH);
      
      // Remove node_modules and package-lock.json to force fresh install
      try {
        execSync('rm -rf node_modules package-lock.json', { encoding: 'utf8' });
      } catch (e) {
        // Ignore if files don't exist
      }
      
      // Attempt npm install
      const installCommand = 'npm install';
      this.log(`Executing: ${installCommand}`);
      
      const result = execSync(installCommand, { 
        encoding: 'utf8', 
        timeout: TEST_TIMEOUT,
        stdio: 'pipe'
      });
      
      this.log('npm install completed successfully');
      this.log(`Install output: ${result}`);
      
      // If we get here, the install succeeded (unexpected for unfixed code)
      return false;
      
    } catch (error) {
      // This is expected for unfixed code
      this.testResults.dependencyResolutionFailed = true;
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'DEPENDENCY_RESOLUTION_FAILURE',
        'npm install failed in js-v3.x directory',
        {
          command: 'npm install',
          exitCode: error.status,
          stderr: error.stderr?.toString(),
          stdout: error.stdout?.toString(),
          packageJsonPath: path.resolve('package.json')
        }
      );
      
      return true; // Expected failure
    } finally {
      // Return to original directory
      process.chdir('../../..');
    }
  }

  /**
   * Test 3: Misc Test Matrix Generation with js-v3.x Included
   * Expected to FAIL or show limited coverage on unfixed code
   */
  async testMiscTestMatrixGeneration() {
    this.log('Testing misc test matrix generation with js-v3.x included...');
    
    try {
      // Change to misc directory
      process.chdir(MISC_PATH);
      
      // Attempt to generate test matrix (list tests without running)
      const listCommand = './run.sh --list-tests --impl-select "~js"';
      this.log(`Executing: ${listCommand}`);
      
      const result = execSync(listCommand, { 
        encoding: 'utf8', 
        timeout: TEST_TIMEOUT,
        stdio: 'pipe'
      });
      
      this.log('Test matrix generation completed');
      this.log(`Matrix output: ${result}`);
      
      // Check if js-v3.x tests are included
      const jsTestCount = (result.match(/js-v3\.x/g) || []).length;
      this.log(`Found ${jsTestCount} js-v3.x test references`);
      
      if (jsTestCount === 0) {
        this.testResults.testMatrixGenerationFailed = true;
        this.addCounterexample(
          'TEST_MATRIX_GENERATION_FAILURE',
          'No js-v3.x tests found in generated matrix',
          {
            command: listCommand,
            output: result,
            jsTestCount: jsTestCount
          }
        );
        return true; // Expected failure
      }
      
      return false; // Unexpected success
      
    } catch (error) {
      // This might be expected for unfixed code
      this.testResults.testMatrixGenerationFailed = true;
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'TEST_MATRIX_GENERATION_ERROR',
        'Test matrix generation command failed',
        {
          command: './run.sh --list-tests --impl-select "~js"',
          exitCode: error.status,
          stderr: error.stderr?.toString(),
          stdout: error.stdout?.toString()
        }
      );
      
      return true; // Expected failure
    } finally {
      // Return to original directory
      process.chdir('..');
    }
  }

  /**
   * Test 4: Misc Protocol Execution with js-v3.x Excluded
   * Expected to show only 1 passing test on unfixed code
   */
  async testMiscProtocolExecutionWithoutJs() {
    this.log('Testing misc protocol execution with js-v3.x excluded...');
    
    try {
      // Change to misc directory
      process.chdir(MISC_PATH);
      
      // Run tests excluding js-v3.x (should show limited coverage)
      const testCommand = './run.sh --impl-ignore "~js" --list-tests';
      this.log(`Executing: ${testCommand}`);
      
      const result = execSync(testCommand, { 
        encoding: 'utf8', 
        timeout: TEST_TIMEOUT,
        stdio: 'pipe'
      });
      
      this.log('Test execution completed');
      this.log(`Test output: ${result}`);
      
      // Parse the output to count selected tests
      const totalMatch = result.match(/Total selected:\s*(\d+)\s*tests/);
      const selectedTestCount = totalMatch ? parseInt(totalMatch[1]) : 0;
      
      this.log(`Found ${selectedTestCount} selected tests without js-v3.x`);
      
      if (selectedTestCount <= 1) {
        this.testResults.limitedTestCoverage = true;
        this.addCounterexample(
          'LIMITED_TEST_COVERAGE',
          `Only ${selectedTestCount} test(s) available without js-v3.x`,
          {
            command: testCommand,
            selectedTestCount: selectedTestCount,
            output: result
          }
        );
        return true; // Expected limited coverage
      }
      
      return false; // Unexpected - more tests available than expected
      
    } catch (error) {
      // This might indicate broader issues
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'TEST_EXECUTION_ERROR',
        'Test execution command failed',
        {
          command: './run.sh --impl-ignore "~js" --list-tests',
          exitCode: error.status,
          stderr: error.stderr?.toString(),
          stdout: error.stdout?.toString()
        }
      );
      
      return true; // Expected failure
    } finally {
      // Return to original directory
      process.chdir('..');
    }
  }

  /**
   * Run all bug condition tests
   * Returns true if bug condition is confirmed (tests fail as expected)
   */
  async runAllTests() {
    this.log('Starting bug condition exploration...');
    this.log('IMPORTANT: These tests are EXPECTED TO FAIL on unfixed code');
    
    const testResults = [];
    
    // Test 1: Docker Build
    this.log('\n=== Test 1: Docker Build Process ===');
    testResults.push(await this.testDockerBuild());
    
    // Test 2: Dependency Resolution
    this.log('\n=== Test 2: Dependency Resolution ===');
    testResults.push(await this.testDependencyResolution());
    
    // Test 3: Test Matrix Generation
    this.log('\n=== Test 3: Test Matrix Generation ===');
    testResults.push(await this.testMiscTestMatrixGeneration());
    
    // Test 4: Limited Test Coverage
    this.log('\n=== Test 4: Test Coverage Without js-v3.x ===');
    testResults.push(await this.testMiscProtocolExecutionWithoutJs());
    
    return testResults;
  }

  /**
   * Generate final report
   */
  generateReport() {
    this.log('\n=== BUG CONDITION EXPLORATION REPORT ===');
    
    this.log(`Total counterexamples found: ${this.counterexamples.length}`);
    
    if (this.counterexamples.length > 0) {
      this.log('\nCOUNTEREXAMPLES THAT DEMONSTRATE THE BUG:');
      this.counterexamples.forEach((ce, index) => {
        this.log(`\n${index + 1}. [${ce.type}] ${ce.description}`);
        if (ce.details) {
          this.log(`   Details: ${JSON.stringify(ce.details, null, 4)}`);
        }
      });
    }
    
    this.log('\nTEST RESULTS SUMMARY:');
    this.log(`- Docker build failed: ${this.testResults.dockerBuildFailed}`);
    this.log(`- Dependency resolution failed: ${this.testResults.dependencyResolutionFailed}`);
    this.log(`- Test matrix generation failed: ${this.testResults.testMatrixGenerationFailed}`);
    this.log(`- Limited test coverage: ${this.testResults.limitedTestCoverage}`);
    
    if (this.testResults.errorMessages.length > 0) {
      this.log('\nERROR MESSAGES:');
      this.testResults.errorMessages.forEach((msg, index) => {
        this.log(`${index + 1}. ${msg}`);
      });
    }
    
    return this.counterexamples.length > 0;
  }
}

/**
 * Main execution
 */
async function main() {
  const explorer = new BugConditionExplorer();
  
  try {
    const testResults = await explorer.runAllTests();
    const bugConfirmed = explorer.generateReport();
    
    if (bugConfirmed) {
      explorer.log('\n✓ BUG CONDITION CONFIRMED: Tests failed as expected');
      explorer.log('This proves the bug exists in the unfixed code');
      explorer.log('Counterexamples have been documented for root cause analysis');
      process.exit(1); // Expected failure - this is SUCCESS for exploration test
    } else {
      explorer.error('\n✗ UNEXPECTED: Tests passed when they should have failed');
      explorer.error('This suggests the bug may not exist or root cause analysis is incorrect');
      explorer.error('Re-investigation may be needed');
      process.exit(0); // Unexpected success - this is FAILURE for exploration test
    }
    
  } catch (error) {
    explorer.error(`\nFATAL ERROR during bug exploration: ${error.message}`);
    explorer.error(error.stack);
    process.exit(2); // Fatal error
  }
}

// Run the test
if (require.main === module) {
  main();
}

module.exports = { BugConditionExplorer };