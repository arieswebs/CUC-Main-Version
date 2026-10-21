import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { storage } from './storage/resource';
import { metaWebhook } from './functions/meta-webhook/resource';
import { FunctionUrlAuthType, HttpMethod } from 'aws-cdk-lib/aws-lambda';
import { CfnOutput } from 'aws-cdk-lib';

/**
 * @see https://docs.amplify.aws/react/build-a-backend/ to add storage, functions, and more
 */
const backend = defineBackend({
  auth,
  data,
  storage,
  metaWebhook,
});

// Grant the metaWebhook Lambda function read/write access to Deals DynamoDB table
const dealsTable = backend.data.resources.tables['Deals'];
if (dealsTable) {
  dealsTable.grantReadWriteData(backend.metaWebhook.resources.lambda);
  backend.metaWebhook.addEnvironment('DEALS_TABLE_NAME', dealsTable.tableName);
}

// Create a public Function URL for Meta Webhook (GET verification, POST events)
const functionUrl = backend.metaWebhook.resources.lambda.addFunctionUrl({
  authType: FunctionUrlAuthType.NONE,
  cors: {
    allowedOrigins: ['*'],
    allowedMethods: [HttpMethod.ALL],
    allowedHeaders: ['*'],
  },
});

// Output the public URL to CloudFormation and amplify_outputs.json
new CfnOutput(backend.stack, 'MetaWebhookUrl', {
  value: functionUrl.url,
  description: 'Public URL to enter in Meta for Developers > Webhooks',
});

backend.addOutput({
  custom: {
    metaWebhookUrl: functionUrl.url,
  },
});

