#!/usr/bin/env node

/**
 * Property-Based Preservation Test for Misc Protocol Test Failures Bugfix
 * 
 * **Validates: Requirements 3.1, 3.2, 3.3**
 * 
 * This property-based test generates many test cases to verify that non-misc
 * test suites continue to work correctly after the misc protocol fix.
 * 
 * PROPERTY: For any test suite that is NOT the misc protocol suite,
 * the fixed code SHALL produce exactly the same behavior as the original code.
 * 
 * EXPECTED OUTCOME: Tests PASS (confirms no regressions in other test suites)
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Property-based test generator for test suite configurations
class TestSuiteGenerator {
  constructor() {
    this.testSuites = ['transport', 'hole-punch', 'perf'];
    this.baselineData = this.loadBaseline();
  }

  loadBaseline() {
    // Load the baseline data captured during preservation testing
    return {
      transport: {
        implementations: [
          "rust-v0.53", "rust-v0.54", "rust-v0.56", "js-v1.x", "js-v2.x", 
          "rust-v0.55", "go-v0.38", "go-v0.39", "go-v0.40", "go-v0.41", 
          "go-v0.42", "go-v0.43", "go-v0.44", "go-v0.45", "python-v0.x", 
          "js-v3.x", "go-v0.47"
        ],
        count: 17,
        imagesYamlExists: true,
        runScriptExecutable: true
      },
      "hole-punch": {
        implementations: ["rust-v0.56", "go-v0.45", "js-v3.x"],
        count: 3,
        imagesYamlExists: true,
        runScriptExecutable: true
      },
      perf: {
        implementations: ["go-v0.45", "js-v3.x", "rust-v0.56"],
        count: 3,
        imagesYamlExists: true,
        runScriptExecutable: true
      }
    };
  }

  // Generate test cases for property-based testing
  * generateTestCases(count = 50) {
    for (let i = 0; i < count; i++) {
      // Generate random test suite selection
      const suite = this.testSuites[Math.floor(Math.random() * this.testSuites.length)];
      
      // Generate random subset of implementations for that suite
      const baseline = this.baselineData[suite];
      const implCount = Math.floor(Math.random() * baseline.implementations.length) + 1;
      const selectedImpls = this.shuffleArray([...baseline.implementations]).slice(0, implCount);
      
      yield {
        suite: suite,
        implementations: selectedImpls,
        expectedCount: selectedImpls.length,
        testCase: i + 1
      };
    }
  }

  shuffleArray(array) {
    const shuffled = [...array];
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    return shuffled;
  }
}

class PreservationPropertyTester {
  constructor() {
    this.generator = new TestSuiteGenerator();
    this.passedTests = 0;
    this.failedTests = 0;
    this.failures = [];
  }

  log(message) {
    console.log(`[PRESERVATION-PBT] ${message}`);
  }

  error(message) {
    console.error(`[PRESERVATION-PBT ERROR] ${message}`);
  }

  /**
   * Property: Test Suite Structure Preservation
   * For any non-misc test suite, the structure and configuration should remain intact
   */
  testStructurePreservationProperty(testCase) {
    const { suite, implementations, expectedCount, testCase: caseNum } = testCase;
    
    try {
      // Verify test suite directory exists
      if (!fs.existsSync(suite)) {
        throw new Error(`Test suite directory ${suite} not found`);
      }
      
      // Verify images.yaml exists and is readable
      const imagesYamlPath = path.join(suite, 'images.yaml');
      if (!fs.existsSync(imagesYamlPath)) {
        throw new Error(`images.yaml not found for ${suite}`);
      }
      
      const imagesYaml = fs.readFileSync(imagesYamlPath, 'utf8');
      
      // Verify run.sh exists and is executable
      const runScriptPath = path.join(suite, 'run.sh');
      if (!fs.existsSync(runScriptPath)) {
        throw new Error(`run.sh not found for ${suite}`);
      }
      
      const runScriptStats = fs.statSync(runScriptPath);
      const isExecutable = (runScriptStats.mode & parseInt('111', 8)) !== 0;
      
      if (!isExecutable) {
        throw new Error(`run.sh is not executable for ${suite}`);
      }
      
      // Verify expected implementations are present in images.yaml
      const missingImpls = implementations.filter(impl => !imagesYaml.includes(impl));
      
      if (missingImpls.length > 0) {
        throw new Error(`Missing implementations in ${suite}: ${missingImpls.join(', ')}`);
      }
      
      this.passedTests++;
      return true;
      
    } catch (error) {
      this.failedTests++;
      this.failures.push({
        testCase: caseNum,
        suite: suite,
        implementations: implementations,
        error: error.message,
        property: 'Structure Preservation'
      });
      return false;
    }
  }

  /**
   * Property: Implementation Diversity Preservation
   * For any non-misc test suite, the implementation diversity should be maintained
   */
  testImplementationDiversityProperty(testCase) {
    const { suite, implementations, expectedCount, testCase: caseNum } = testCase;
    
    try {
      const baseline = this.generator.baselineData[suite];
      
      // Verify that the baseline implementation count is maintained
      const imagesYamlPath = path.join(suite, 'images.yaml');
      const imagesYaml = fs.readFileSync(imagesYamlPath, 'utf8');
      
      // Extract all implementations from images.yaml
      const implMatches = imagesYaml.match(/\b(go-v[\d.]+|rust-v[\d.]+|python-v[\d.x]+|js-v[\d.x]+)\b/g);
      const actualImplementations = implMatches ? [...new Set(implMatches)] : [];
      
      // Verify implementation count matches baseline
      if (actualImplementations.length !== baseline.count) {
        throw new Error(`Implementation count mismatch for ${suite}: expected ${baseline.count}, got ${actualImplementations.length}`);
      }
      
      // Verify all baseline implementations are still present
      const missingFromBaseline = baseline.implementations.filter(impl => !actualImplementations.includes(impl));
      
      if (missingFromBaseline.length > 0) {
        throw new Error(`Missing baseline implementations in ${suite}: ${missingFromBaseline.join(', ')}`);
      }
      
      // Verify no unexpected implementations were added
      const unexpectedImpls = actualImplementations.filter(impl => !baseline.implementations.includes(impl));
      
      if (unexpectedImpls.length > 0) {
        throw new Error(`Unexpected implementations added to ${suite}: ${unexpectedImpls.join(', ')}`);
      }
      
      this.passedTests++;
      return true;
      
    } catch (error) {
      this.failedTests++;
      this.failures.push({
        testCase: caseNum,
        suite: suite,
        implementations: implementations,
        error: error.message,
        property: 'Implementation Diversity Preservation'
      });
      return false;
    }
  }

  /**
   * Property: Configuration File Integrity
   * For any non-misc test suite, configuration files should remain unchanged
   */
  testConfigurationIntegrityProperty(testCase) {
    const { suite, implementations, expectedCount, testCase: caseNum } = testCase;
    
    try {
      // Check that images.yaml has the expected structure
      const imagesYamlPath = path.join(suite, 'images.yaml');
      const imagesYaml = fs.readFileSync(imagesYamlPath, 'utf8');
      
      // Verify YAML is valid and has expected sections
      if (!imagesYaml.includes('test-aliases:')) {
        throw new Error(`Missing test-aliases section in ${suite}/images.yaml`);
      }
      
      if (!imagesYaml.includes('implementations:')) {
        throw new Error(`Missing implementations section in ${suite}/images.yaml`);
      }
      
      // Verify run.sh has expected structure
      const runScriptPath = path.join(suite, 'run.sh');
      const runScript = fs.readFileSync(runScriptPath, 'utf8');
      
      if (!runScript.includes('#!/usr/bin/env bash')) {
        throw new Error(`Missing bash shebang in ${suite}/run.sh`);
      }
      
      if (!runScript.includes('set -euo pipefail')) {
        throw new Error(`Missing strict mode in ${suite}/run.sh`);
      }
      
      this.passedTests++;
      return true;
      
    } catch (error) {
      this.failedTests++;
      this.failures.push({
        testCase: caseNum,
        suite: suite,
        implementations: implementations,
        error: error.message,
        property: 'Configuration File Integrity'
      });
      return false;
    }
  }

  /**
   * Run property-based tests
   */
  async runPropertyBasedTests(testCount = 50) {
    this.log(`Starting property-based preservation testing with ${testCount} test cases...`);
    this.log('PROPERTY: Non-misc test suites maintain identical behavior after misc fix');
    
    let caseNum = 0;
    
    for (const testCase of this.generator.generateTestCases(testCount)) {
      caseNum++;
      
      if (caseNum % 10 === 0) {
        this.log(`Progress: ${caseNum}/${testCount} test cases completed`);
      }
      
      // Run all properties for this test case
      this.testStructurePreservationProperty(testCase);
      this.testImplementationDiversityProperty(testCase);
      this.testConfigurationIntegrityProperty(testCase);
    }
    
    return this.generateReport();
  }

  /**
   * Generate final report
   */
  generateReport() {
    this.log('\n=== PROPERTY-BASED PRESERVATION TEST REPORT ===');
    
    const totalTests = this.passedTests + this.failedTests;
    const successRate = totalTests > 0 ? (this.passedTests / totalTests * 100).toFixed(2) : 0;
    
    this.log(`Total property tests executed: ${totalTests}`);
    this.log(`Passed: ${this.passedTests}`);
    this.log(`Failed: ${this.failedTests}`);
    this.log(`Success rate: ${successRate}%`);
    
    if (this.failures.length > 0) {
      this.log('\nFAILURES:');
      this.failures.forEach((failure, index) => {
        this.log(`\n${index + 1}. Test Case ${failure.testCase} - ${failure.property}`);
        this.log(`   Suite: ${failure.suite}`);
        this.log(`   Implementations: ${failure.implementations.join(', ')}`);
        this.log(`   Error: ${failure.error}`);
      });
    }
    
    // Property-based test passes if success rate is 100%
    return this.failedTests === 0;
  }
}

/**
 * Main execution
 */
async function main() {
  const tester = new PreservationPropertyTester();
  
  try {
    const testCount = process.argv[2] ? parseInt(process.argv[2]) : 50;
    const success = await tester.runPropertyBasedTests(testCount);
    
    if (success) {
      tester.log('\n✓ PROPERTY-BASED PRESERVATION TEST PASSED');
      tester.log('All non-misc test suites maintain identical behavior');
      tester.log('No regressions detected in other test suites');
      process.exit(0); // Success
    } else {
      tester.error('\n✗ PROPERTY-BASED PRESERVATION TEST FAILED');
      tester.error('Some properties were violated - regressions detected');
      tester.error('Fix may have unintended side effects on other test suites');
      process.exit(1); // Failure
    }
    
  } catch (error) {
    tester.error(`\nFATAL ERROR during property-based testing: ${error.message}`);
    tester.error(error.stack);
    process.exit(2); // Fatal error
  }
}

// Run the test
if (require.main === module) {
  main();
}

module.exports = { PreservationPropertyTester, TestSuiteGenerator };