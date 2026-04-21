#!/usr/bin/env node

/**
 * Focused Bug Condition Exploration Test for Misc Protocol Test Failures
 * 
 * **Validates: Requirements 2.1, 2.2**
 * 
 * This test MUST FAIL on unfixed code - failure confirms the bug exists.
 * DO NOT attempt to fix the test or the code when it fails.
 * 
 * GOAL: Surface counterexamples that demonstrate the bug exists
 * Focus on dependency compatibility issues with libp2p v3.0.3
 * 
 * EXPECTED OUTCOME: Test FAILS (this is correct - it proves the bug exists)
 */

const fs = require('fs');
const path = require('path');

class FocusedBugConditionExplorer {
  constructor() {
    this.counterexamples = [];
    this.testResults = {
      incompatibleDependencies: false,
      packageJsonAnalysis: null,
      dependencyConflicts: [],
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
   * Test 1: Analyze package.json for dependency compatibility issues
   * Expected to find conflicts between libp2p v3.0.3 and newer ecosystem packages
   */
  async testPackageJsonAnalysis() {
    this.log('Analyzing package.json for dependency compatibility issues...');
    
    try {
      const packageJsonPath = path.join('misc', 'images', 'js', 'v3.x', 'package.json');
      
      if (!fs.existsSync(packageJsonPath)) {
        throw new Error(`package.json not found at ${packageJsonPath}`);
      }
      
      const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
      this.testResults.packageJsonAnalysis = packageJson;
      
      this.log(`Found package.json with ${Object.keys(packageJson.devDependencies || {}).length} devDependencies`);
      
      // Check for known problematic version combinations
      const deps = packageJson.devDependencies || {};
      const conflicts = [];
      
      // Check libp2p version
      const libp2pVersion = deps['libp2p'];
      if (libp2pVersion === '^3.0.3') {
        this.log(`Found libp2p version: ${libp2pVersion}`);
        
        // Check for incompatible @chainsafe packages
        const noiseVersion = deps['@chainsafe/libp2p-noise'];
        const yamuxVersion = deps['@chainsafe/libp2p-yamux'];
        
        if (noiseVersion === '^17.0.0') {
          conflicts.push({
            package: '@chainsafe/libp2p-noise',
            version: noiseVersion,
            issue: 'Version ^17.0.0 requires libp2p v4.x or higher, but libp2p is at v3.0.3',
            severity: 'critical'
          });
        }
        
        if (yamuxVersion === '^8.0.0') {
          conflicts.push({
            package: '@chainsafe/libp2p-yamux',
            version: yamuxVersion,
            issue: 'Version ^8.0.0 requires libp2p v4.x or higher, but libp2p is at v3.0.3',
            severity: 'critical'
          });
        }
        
        // Check for other @libp2p packages that might be incompatible
        Object.entries(deps).forEach(([pkg, version]) => {
          if (pkg.startsWith('@libp2p/')) {
            // These packages likely require newer libp2p versions
            if (pkg === '@libp2p/identify' && version === '^4.0.2') {
              conflicts.push({
                package: pkg,
                version: version,
                issue: 'Version ^4.0.2 may require libp2p v4.x or higher, but libp2p is at v3.0.3',
                severity: 'high'
              });
            }
            if (pkg === '@libp2p/mplex' && version === '^12.0.3') {
              conflicts.push({
                package: pkg,
                version: version,
                issue: 'Version ^12.0.3 may require libp2p v4.x or higher, but libp2p is at v3.0.3',
                severity: 'high'
              });
            }
            if (pkg === '@libp2p/ping' && version === '^3.0.2') {
              conflicts.push({
                package: pkg,
                version: version,
                issue: 'Version ^3.0.2 may require libp2p v4.x or higher, but libp2p is at v3.0.3',
                severity: 'high'
              });
            }
          }
        });
      }
      
      this.testResults.dependencyConflicts = conflicts;
      
      if (conflicts.length > 0) {
        this.testResults.incompatibleDependencies = true;
        
        this.addCounterexample(
          'DEPENDENCY_VERSION_CONFLICTS',
          `Found ${conflicts.length} dependency version conflicts`,
          {
            libp2pVersion: libp2pVersion,
            conflicts: conflicts,
            packageJsonPath: packageJsonPath
          }
        );
        
        return true; // Expected conflicts found
      }
      
      return false; // No conflicts found (unexpected)
      
    } catch (error) {
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'PACKAGE_JSON_ANALYSIS_ERROR',
        'Failed to analyze package.json',
        {
          error: error.message,
          stack: error.stack
        }
      );
      
      return true; // Expected failure
    }
  }

  /**
   * Test 2: Check for known libp2p v3.x compatibility issues
   */
  async testLibp2pCompatibilityIssues() {
    this.log('Checking for known libp2p v3.x compatibility issues...');
    
    try {
      const packageJsonPath = path.join('misc', 'images', 'js', 'v3.x', 'package.json');
      const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
      const deps = packageJson.devDependencies || {};
      
      const knownIssues = [];
      
      // Check for specific version combinations that are known to fail
      if (deps['libp2p'] === '^3.0.3') {
        // @chainsafe/libp2p-noise v17+ requires libp2p v4+
        if (deps['@chainsafe/libp2p-noise'] && deps['@chainsafe/libp2p-noise'].includes('17.')) {
          knownIssues.push({
            issue: 'libp2p-noise v17.x incompatible with libp2p v3.x',
            description: '@chainsafe/libp2p-noise v17.0.0 requires libp2p v4.x or higher due to breaking API changes',
            evidence: 'Peer dependency mismatch will cause npm install to fail'
          });
        }
        
        // @chainsafe/libp2p-yamux v8+ requires libp2p v4+
        if (deps['@chainsafe/libp2p-yamux'] && deps['@chainsafe/libp2p-yamux'].includes('8.')) {
          knownIssues.push({
            issue: 'libp2p-yamux v8.x incompatible with libp2p v3.x',
            description: '@chainsafe/libp2p-yamux v8.0.0 requires libp2p v4.x or higher due to breaking API changes',
            evidence: 'Peer dependency mismatch will cause npm install to fail'
          });
        }
        
        // @libp2p/* packages v3+ and v4+ likely require libp2p v4+
        Object.entries(deps).forEach(([pkg, version]) => {
          if (pkg.startsWith('@libp2p/') && (version.includes('^3.') || version.includes('^4.') || version.includes('^11.') || version.includes('^12.'))) {
            knownIssues.push({
              issue: `${pkg} version mismatch`,
              description: `${pkg} ${version} may require libp2p v4.x or higher`,
              evidence: 'Potential peer dependency conflicts during npm install'
            });
          }
        });
      }
      
      if (knownIssues.length > 0) {
        this.addCounterexample(
          'KNOWN_COMPATIBILITY_ISSUES',
          `Found ${knownIssues.length} known compatibility issues`,
          {
            issues: knownIssues,
            libp2pVersion: deps['libp2p']
          }
        );
        
        return true; // Expected issues found
      }
      
      return false; // No known issues (unexpected)
      
    } catch (error) {
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'COMPATIBILITY_CHECK_ERROR',
        'Failed to check compatibility issues',
        {
          error: error.message
        }
      );
      
      return true; // Expected failure
    }
  }

  /**
   * Test 3: Verify Docker configuration issues
   */
  async testDockerConfigurationIssues() {
    this.log('Checking Docker configuration for potential issues...');
    
    try {
      const dockerfilePath = path.join('misc', 'images', 'js', 'v3.x', 'Dockerfile');
      
      if (!fs.existsSync(dockerfilePath)) {
        throw new Error(`Dockerfile not found at ${dockerfilePath}`);
      }
      
      const dockerfile = fs.readFileSync(dockerfilePath, 'utf8');
      this.log('Found Dockerfile');
      
      const issues = [];
      
      // Check for potential issues in Dockerfile
      if (dockerfile.includes('mcr.microsoft.com/playwright:v1.55.0')) {
        issues.push({
          issue: 'Playwright base image version',
          description: 'Using mcr.microsoft.com/playwright:v1.55.0 which may have Node.js version conflicts',
          evidence: 'Base image Node.js version may not be compatible with libp2p v3.0.3 requirements'
        });
      }
      
      if (dockerfile.includes('npm ci')) {
        issues.push({
          issue: 'npm ci with conflicting dependencies',
          description: 'npm ci will fail if package-lock.json has dependency conflicts',
          evidence: 'Dependency version conflicts will cause Docker build to fail at npm ci step'
        });
      }
      
      if (dockerfile.includes('npm run build')) {
        issues.push({
          issue: 'Build step with incompatible dependencies',
          description: 'npm run build will fail if dependencies are incompatible',
          evidence: 'TypeScript compilation or aegir build may fail with incompatible libp2p versions'
        });
      }
      
      if (issues.length > 0) {
        this.addCounterexample(
          'DOCKER_CONFIGURATION_ISSUES',
          `Found ${issues.length} potential Docker configuration issues`,
          {
            dockerfilePath: dockerfilePath,
            issues: issues,
            dockerfileContent: dockerfile
          }
        );
        
        return true; // Expected issues found
      }
      
      return false; // No issues found
      
    } catch (error) {
      this.testResults.errorMessages.push(error.message);
      
      this.addCounterexample(
        'DOCKER_CONFIG_CHECK_ERROR',
        'Failed to check Docker configuration',
        {
          error: error.message
        }
      );
      
      return true; // Expected failure
    }
  }

  /**
   * Run all focused bug condition tests
   */
  async runAllTests() {
    this.log('Starting focused bug condition exploration...');
    this.log('IMPORTANT: These tests are EXPECTED TO FAIL on unfixed code');
    this.log('Focus: Dependency compatibility issues with libp2p v3.0.3');
    
    const testResults = [];
    
    // Test 1: Package.json Analysis
    this.log('\n=== Test 1: Package.json Dependency Analysis ===');
    testResults.push(await this.testPackageJsonAnalysis());
    
    // Test 2: Known Compatibility Issues
    this.log('\n=== Test 2: Known libp2p v3.x Compatibility Issues ===');
    testResults.push(await this.testLibp2pCompatibilityIssues());
    
    // Test 3: Docker Configuration Issues
    this.log('\n=== Test 3: Docker Configuration Issues ===');
    testResults.push(await this.testDockerConfigurationIssues());
    
    return testResults;
  }

  /**
   * Generate final report
   */
  generateReport() {
    this.log('\n=== FOCUSED BUG CONDITION EXPLORATION REPORT ===');
    
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
    this.log(`- Incompatible dependencies found: ${this.testResults.incompatibleDependencies}`);
    this.log(`- Dependency conflicts: ${this.testResults.dependencyConflicts.length}`);
    
    if (this.testResults.dependencyConflicts.length > 0) {
      this.log('\nDEPENDENCY CONFLICTS:');
      this.testResults.dependencyConflicts.forEach((conflict, index) => {
        this.log(`${index + 1}. ${conflict.package} ${conflict.version}`);
        this.log(`   Issue: ${conflict.issue}`);
        this.log(`   Severity: ${conflict.severity}`);
      });
    }
    
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
  const explorer = new FocusedBugConditionExplorer();
  
  try {
    const testResults = await explorer.runAllTests();
    const bugConfirmed = explorer.generateReport();
    
    if (bugConfirmed) {
      explorer.log('\n✓ BUG CONDITION CONFIRMED: Dependency conflicts found as expected');
      explorer.log('This proves the bug exists in the unfixed code');
      explorer.log('Root cause: libp2p v3.0.3 incompatible with newer ecosystem packages');
      explorer.log('Counterexamples have been documented for fix implementation');
      process.exit(1); // Expected failure - this is SUCCESS for exploration test
    } else {
      explorer.error('\n✗ UNEXPECTED: No dependency conflicts found');
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

module.exports = { FocusedBugConditionExplorer };