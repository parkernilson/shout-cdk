#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { CdkStack } from '../lib/cdk-stack';

try {
  process.loadEnvFile('.env');
} catch {
  // No .env file; rely on the shell environment.
}

const app = new cdk.App();
new CdkStack(app, 'CdkStack', {
  // Account/region come from the gitignored .env (see .env.example), falling
  // back to whatever the active AWS profile resolves to.
  env: {
    account: process.env.CDK_ACCOUNT ?? process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_REGION ?? process.env.CDK_DEFAULT_REGION,
  },
});
