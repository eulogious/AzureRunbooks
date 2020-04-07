# AzureRunbooks

AutoScaleWVD.ps1 
This script is for use with Azure Windows Virtual Desktop pools and will allows you to scale your pool up and down based on metrics 
defined in the logic app. Complete information is in the script to assist.

Example Logic App:
{
        "definition": { 
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "actions": {
                "HTTP_Webhook": {
                    "inputs": {
                        "subscribe": {
                            "body": {
                                "ConnectionAssetName": "<RunAsConnectionName>",
                                "RDBrokerURL": "https://rdbroker.wvd.microsoft.com",
                                "aadTenantId": "<AADTenant>",
                                "azureSubId": "<AzureSubscriptionId>",
                                "callbackUrl": "@{listCallbackUrl()}",
                                "endPeakTime": "18:00:00",
                                "hostpoolname": "<WVDHostPoolName>",
                                "peakServerStartThreshold": "2",
                                "peakday": [
                                    "Monday",
                                    "Tuesday",
                                    "Wednesday",
                                    "Thursday",
                                    "Friday"
                                ],
                                "serverStartThreshold": "1",
                                "sessionHostRg": "<WVDHostPoolResourceGroup>",
                                "startPeakTime": "06:00:00",
                                "tenantName": "<WVDTenantName>",
                                "usePeak": "yes",
                                "utcoffset": "-7"
                            },
                            "method": "POST",
                            "uri": "<RunbookWebhookUrl>"
                        },
                        "unsubscribe": {}
                    },
                    "runAfter": {},
                    "type": "HttpWebhook"
                }
            },
            "contentVersion": "1.0.0.0",
            "outputs": {},
            "parameters": {},
            "triggers": {
                "Recurrence": {
                    "recurrence": {
                        "frequency": "Minute",
                        "interval": 5
                    },
                    "type": "Recurrence"
                }
            }
        },
        "parameters": {}
  }
