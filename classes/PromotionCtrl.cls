public without sharing class PromotionCtrl {

    private static final String  GITHUB_API_BASE = 'https://api.github.com';
    private static final String  API_VERSION     = '64.0';
    private static final Integer TIMEOUT_MS      = 120000;

    private static final Set<String> SKIP_COMPONENTS = new Set<String>{
        'OAuthCallbackCtrl', 'OAuthCallback'
    };

    // ═══════════════════════════════════════════════════════════
    // GET ACTIVE COMMIT INFO
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getActiveCommitInfo(String userStoryId) {
        try {
            List<Commit__c> commits = [
                SELECT Id, Branch_Name__c, Commit_ID__c, Commit_Message__c, CreatedDate
                FROM Commit__c
                WHERE User_Story_Name__c = :userStoryId
                AND Status__c = 'Active'
                AND Branch_Name__c != null
                ORDER BY CreatedDate DESC
            ];

            if (commits.isEmpty()) {
                return new Map<String, Object>{ 'hasActiveCommit' => false };
            }

            List<Map<String, Object>> commitList = new List<Map<String, Object>>();
            for (Commit__c c : commits) {
                commitList.add(new Map<String, Object>{
                    'commitId'      => c.Id,
                    'branchName'    => c.Branch_Name__c,
                    'commitSha'     => c.Commit_ID__c,
                    'commitMessage' => c.Commit_Message__c
                });
            }

            List<String> allActiveShas = new List<String>();
            for (Commit__c c : commits) {
                if (String.isNotBlank(c.Commit_ID__c)) allActiveShas.add(c.Commit_ID__c);
            }

            Integer totalComponents = [
                SELECT COUNT()
                FROM Component__c
                WHERE User_Story_Name__c = :userStoryId
                AND Commit_ID__c IN :allActiveShas
            ];

            return new Map<String, Object>{
                'hasActiveCommit'  => true,
                'commits'          => commitList,
                'commitId'         => commits[0].Id,
                'branchName'       => commits[0].Branch_Name__c,
                'commitSha'        => commits[0].Commit_ID__c,
                'commitMessage'    => commits[0].Commit_Message__c,
                'totalComponents'  => totalComponents,
                'allActiveShas'    => allActiveShas
            };
        } catch (Exception e) {
            throw createAuraException('getActiveCommitInfo: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET ORG DETAILS
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, String> getOrgDetails(String userStoryId) {
        try {
            User_Story_Name__c us = [
                SELECT Target_Org__c,
                       Target_Org__r.Org_Name__c,
                       Target_Org__r.Org_Type__c,
                       Target_Org__r.Refresh_Token__c,
                       Target_Org__r.Connection_Status__c,
                       Source_Org__c,
                       Source_Org__r.Org_Name__c,
                       Source_Org__r.Org_Type__c,
                       Source_Org__r.Refresh_Token__c,
                       GitHub_Connection__c,
                       GitHub_Connection__r.Repo_Owner__c,
                       GitHub_Connection__r.Repo_Name__c,
                       GitHub_Connection__r.Access_Token__c,
                       GitHub_Connection__r.Status__c
                FROM User_Story_Name__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];

            if (us.Target_Org__c == null)
                throw createAuraException('Target Org is not selected on the User Story.');
            if (String.isBlank(us.Target_Org__r.Refresh_Token__c))
                throw createAuraException('Target Org "' + us.Target_Org__r.Org_Name__c + '" is not connected. Please go to Environments app and Connect Org.');

            if (us.Source_Org__c == null)
                throw createAuraException('Source Org is not selected on the User Story.');
            if (String.isBlank(us.Source_Org__r.Refresh_Token__c))
                throw createAuraException('Source Org "' + us.Source_Org__r.Org_Name__c + '" is not connected. Please go to Environments app and Connect Org.');

            if (us.GitHub_Connection__c == null)
                throw createAuraException('No GitHub Connection assigned to this User Story.');
            if (us.GitHub_Connection__r.Status__c != 'Connected')
                throw createAuraException('GitHub Connection is not active.');

            return new Map<String, String>{
                'targetOrgName'      => us.Target_Org__r.Org_Name__c,
                'targetOrgType'      => us.Target_Org__r.Org_Type__c,
                'targetRefreshToken' => us.Target_Org__r.Refresh_Token__c,
                'sourceOrgName'      => us.Source_Org__r.Org_Name__c,
                'sourceOrgType'      => us.Source_Org__r.Org_Type__c,
                'sourceRefreshToken' => us.Source_Org__r.Refresh_Token__c,
                'repoOwner'          => us.GitHub_Connection__r.Repo_Owner__c,
                'repoName'           => us.GitHub_Connection__r.Repo_Name__c,
                'githubToken'        => us.GitHub_Connection__r.Access_Token__c
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getOrgDetails: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // REFRESH TOKEN
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, String> refreshToken(
            String refreshToken, String orgType, String orgName) {
        try {
            List<OAuth_Config__mdt> configs = [
                SELECT Client_Id__c, Client_Secret__c
                FROM OAuth_Config__mdt
                WHERE App_Type__c = 'Salesforce'
                AND DeveloperName = :orgName.capitalize()
                LIMIT 1
            ];
            if (configs.isEmpty()) {
                configs = [
                    SELECT Client_Id__c, Client_Secret__c
                    FROM OAuth_Config__mdt
                    WHERE DeveloperName = 'Default'
                    LIMIT 1
                ];
            }

            OAuth_Config__mdt config    = configs[0];
            Boolean           isSandbox = (orgType != null && orgType.toLowerCase() == 'sandbox');
            String tokenEndpoint = isSandbox
                ? 'https://test.salesforce.com/services/oauth2/token'
                : 'https://login.salesforce.com/services/oauth2/token';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(tokenEndpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody(
                'grant_type=refresh_token'
                + '&client_id='     + EncodingUtil.urlEncode(config.Client_Id__c,     'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c, 'UTF-8')
                + '&refresh_token=' + EncodingUtil.urlEncode(refreshToken,            'UTF-8')
            );
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                String body = res.getBody();
                String friendlyMsg;
                if (body.contains('invalid_grant') || body.contains('expired')) {
                    friendlyMsg = '⚠️ ' + (isSandbox ? 'Sandbox' : 'Production') + ' org refresh token has either expired or been revoked. Please go to the Environments app and click the "Connect Org" button for this org to reconnect it. This will generate a fresh token.';
                } else {
                    friendlyMsg = 'Token refresh failed: ' + body;
                }
                throw createAuraException(friendlyMsg);
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return new Map<String, String>{
                'accessToken' => String.valueOf(parsed.get('access_token')),
                'instanceUrl' => String.valueOf(parsed.get('instance_url'))
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('refreshToken: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET ACTIVE COMPONENTS FOR VALIDATION
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getActiveComponentsForValidation(String userStoryId) {
        try {
            List<Commit__c> activeCommits = [
                SELECT Commit_ID__c
                FROM Commit__c
                WHERE User_Story_Name__c = :userStoryId
                AND Status__c = 'Active'
            ];

            Set<String> activeCommitShas = new Set<String>();
            for (Commit__c c : activeCommits) {
                if (String.isNotBlank(c.Commit_ID__c)) activeCommitShas.add(c.Commit_ID__c);
            }

            if (activeCommitShas.isEmpty()) return new List<Map<String, String>>();

            List<Component__c> comps = [
                SELECT Component_Name__c, Metadata_Type__c
                FROM Component__c
                WHERE User_Story_Name__c = :userStoryId
                AND Commit_ID__c IN :activeCommitShas
            ];

            List<Map<String, String>> result = new List<Map<String, String>>();
            Set<String> seen = new Set<String>();

            for (Component__c c : comps) {
                String key = c.Metadata_Type__c + '#' + c.Component_Name__c;
                if (seen.contains(key)) continue;
                seen.add(key);
                result.add(new Map<String, String>{
                    'name'         => c.Component_Name__c,
                    'metadataType' => c.Metadata_Type__c
                });
            }

            return result;

        } catch (Exception e) {
            throw createAuraException('getActiveComponentsForValidation: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // STEP 1 of 3 — DML ONLY
    // Promotion__c record create/update karo
    // Koi callout nahi — sirf DML
    // Returns: promotionId, promotionBranch, repoOwner, repoName, githubToken
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, String> createPromotionRecord(
            String  userStoryId,
            String  featureBranch,
            String  commitSha,
            Integer totalComponents) {
        try {
            User_Story_Name__c us = [
                SELECT Name,
                       GitHub_Connection__r.Repo_Owner__c,
                       GitHub_Connection__r.Repo_Name__c,
                       GitHub_Connection__r.Access_Token__c
                FROM User_Story_Name__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];

            List<Promotion__c> existing = [
                SELECT Id, Name FROM Promotion__c
                WHERE User_Story__c = :userStoryId
                AND Status__c NOT IN ('Deployed')
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            Promotion__c promo;
            if (!existing.isEmpty()) {
                // Existing record update karo — pehle bina promoBranch ke
                promo = existing[0];
                promo.Status__c           = 'Pending';
                promo.Feature_Branch__c   = featureBranch;
                promo.Commit_SHA__c       = commitSha;
                promo.Total_Components__c = totalComponents;
                promo.Validation_Error__c = null;
                promo.Job_ID__c           = null;
                update promo;
            } else {
                // Naya record insert karo — promoBranch baad mein update hoga
                promo = new Promotion__c(
                    User_Story__c         = userStoryId,
                    Status__c             = 'Pending',
                    Feature_Branch__c     = featureBranch,
                    Commit_SHA__c         = commitSha,
                    Total_Components__c   = totalComponents
                );
                insert promo;
                // Insert ke baad Name (autonumber) fetch karo
                promo = [SELECT Id, Name FROM Promotion__c WHERE Id = :promo.Id LIMIT 1];
            }

            // Promotion__c ka autonumber Name se branch banao — e.g. promotion/PROMO-0009
            String safeName    = promo.Name.replaceAll('[^a-zA-Z0-9-]', '-');
            String promoBranch = 'promotion/' + safeName;

            // promoBranch ab record pe save karo
            promo.Promotion_Branch__c = promoBranch;
            update promo;

            // Sab kuch return karo jo GitHub callout ke liye chahiye
            return new Map<String, String>{
                'promotionId'     => promo.Id,
                'promotionBranch' => promoBranch,
                'repoOwner'       => us.GitHub_Connection__r.Repo_Owner__c,
                'repoName'        => us.GitHub_Connection__r.Repo_Name__c,
                'githubToken'     => us.GitHub_Connection__r.Access_Token__c
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('createPromotionRecord: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // STEP 2 of 3 — CALLOUTS ONLY
    // GitHub pe promotion branch create/update karo
    // Koi DML nahi — sirf HTTP callouts
    // Returns: promotionId, promotionBranch, featureSha
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, String> createPromotionBranchOnGitHub(
            String promotionId,
            String featureBranch,
            String promoBranch,
            String owner,
            String repo,
            String token) {
        try {
            // ── Feature branch ka latest SHA lo ─────────────────────
            HttpRequest shaReq = new HttpRequest();
            shaReq.setEndpoint(GITHUB_API_BASE + '/repos/' + owner + '/' + repo
                + '/git/ref/heads/' + featureBranch);
            shaReq.setMethod('GET');
            shaReq.setHeader('Authorization', 'Bearer ' + token);
            shaReq.setHeader('Accept', 'application/vnd.github+json');
            shaReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            shaReq.setTimeout(TIMEOUT_MS);
            HttpResponse shaRes = new Http().send(shaReq);

            if (shaRes.getStatusCode() != 200) {
                throw createAuraException('Feature branch not found: ' + featureBranch
                    + '. Please ensure the branch exists on GitHub.');
            }

            Map<String, Object> shaData  = (Map<String, Object>) JSON.deserializeUntyped(shaRes.getBody());
            String featureSha = String.valueOf(
                ((Map<String, Object>) shaData.get('object')).get('sha'));

            // ── Promotion branch create karo ─────────────────────────
            HttpRequest branchReq = new HttpRequest();
            branchReq.setEndpoint(GITHUB_API_BASE + '/repos/' + owner + '/' + repo + '/git/refs');
            branchReq.setMethod('POST');
            branchReq.setHeader('Authorization', 'Bearer ' + token);
            branchReq.setHeader('Accept', 'application/vnd.github+json');
            branchReq.setHeader('Content-Type', 'application/json');
            branchReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            branchReq.setBody(JSON.serialize(new Map<String, String>{
                'ref' => 'refs/heads/' + promoBranch,
                'sha' => featureSha
            }));
            branchReq.setTimeout(TIMEOUT_MS);
            HttpResponse branchRes = new Http().send(branchReq);

            if (branchRes.getStatusCode() == 422) {
                // Branch already exists — force update karo
                HttpRequest updateReq = new HttpRequest();
                updateReq.setEndpoint(GITHUB_API_BASE + '/repos/' + owner + '/' + repo
                    + '/git/refs/heads/' + promoBranch);
                updateReq.setMethod('PATCH');
                updateReq.setHeader('Authorization', 'Bearer ' + token);
                updateReq.setHeader('Accept', 'application/vnd.github+json');
                updateReq.setHeader('Content-Type', 'application/json');
                updateReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
                updateReq.setBody(JSON.serialize(new Map<String, Object>{
                    'sha'   => featureSha,
                    'force' => true
                }));
                updateReq.setTimeout(TIMEOUT_MS);
                HttpResponse updateRes = new Http().send(updateReq);
                if (updateRes.getStatusCode() != 200)
                    throw createAuraException('Promotion branch update failed: ' + updateRes.getBody());

            } else if (branchRes.getStatusCode() != 201) {
                throw createAuraException('Promotion branch creation failed: ' + branchRes.getBody());
            }

            return new Map<String, String>{
                'promotionId'     => promotionId,
                'promotionBranch' => promoBranch,
                'featureSha'      => featureSha
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('createPromotionBranchOnGitHub: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // STEP 3 of 3 — DML ONLY
    // Resolved featureSha ko Promotion__c record pe save karo
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static void savePromotionSha(String promotionId, String featureSha) {
        try {
            Promotion__c promo = new Promotion__c(
                Id          = promotionId,
                Commit_SHA__c = featureSha
            );
            update promo;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('savePromotionSha: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET FILE CONTENT FROM GITHUB
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String getFileContent(
            String repoOwner, String repoName,
            String githubToken, String fileSha) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(GITHUB_API_BASE + '/repos/' + repoOwner + '/' + repoName
                + '/git/blobs/' + fileSha);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + githubToken);
            req.setHeader('Accept', 'application/vnd.github+json');
            req.setHeader('X-GitHub-Api-Version', '2022-11-28');
            req.setTimeout(TIMEOUT_MS);
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200)
                throw createAuraException('File fetch failed: ' + res.getBody());

            Map<String, Object> data    = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String              content = String.valueOf(data.get('content'));
            content = content.replaceAll('\\n', '').replaceAll('\\r', '');
            return content;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getFileContent: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // START VALIDATE (on promotion branch / target org)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String startValidate(
            String zipBase64, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"' +
                ' xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken +
                '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:deploy>' +
                '<met:ZipFile>' + zipBase64 + '</met:ZipFile>' +
                '<met:DeployOptions>' +
                '<met:allowMissingFiles>true</met:allowMissingFiles>' +
                '<met:autoUpdatePackage>false</met:autoUpdatePackage>' +
                '<met:checkOnly>true</met:checkOnly>' +
                '<met:ignoreWarnings>true</met:ignoreWarnings>' +
                '<met:performRetrieve>false</met:performRetrieve>' +
                '<met:purgeOnDelete>false</met:purgeOnDelete>' +
                '<met:rollbackOnError>true</met:rollbackOnError>' +
                '<met:runAllTests>true</met:runAllTests>' +
                '<met:singlePackage>true</met:singlePackage>' +
                '</met:DeployOptions>' +
                '</met:deploy></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(res.getBody(), 'faultstring');
                throw createAuraException('Validate Start Failed: ' + (fault != null ? fault : res.getBody()));
            }
            String jobId = extractTagValue(res.getBody(), 'id');
            if (String.isBlank(jobId)) throw createAuraException('Job ID is blank.');
            return jobId;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('startValidate: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // CHECK VALIDATE STATUS
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> checkValidateStatus(
            String jobId, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"' +
                ' xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken +
                '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:checkDeployStatus>' +
                '<met:asyncProcessId>' + jobId + '</met:asyncProcessId>' +
                '<met:includeDetails>true</met:includeDetails>' +
                '</met:checkDeployStatus></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res  = new Http().send(req);
            String       body = res.getBody();

            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(body, 'faultstring');
                throw createAuraException('checkValidateStatus Error: ' + (fault != null ? fault : body));
            }

            String  done   = extractTagValue(body, 'done');
            Boolean isDone = done == 'true';

            if (!isDone) {
                Integer compsDone  = 0;
                Integer compsTotal = 0;
                try {
                    String cd = extractTagValue(body, 'numberComponentsDeployed');
                    String ct = extractTagValue(body, 'numberComponentsTotal');
                    if (cd != null) compsDone  = Integer.valueOf(cd);
                    if (ct != null) compsTotal = Integer.valueOf(ct);
                } catch (Exception ex) {}
                String stateDetail = extractTagValue(body, 'stateDetail');
                return new Map<String, Object>{
                    'status'          => 'InProgress',
                    'stateDetail'     => String.isNotBlank(stateDetail) ? stateDetail : 'Validating...',
                    'componentsDone'  => compsDone,
                    'componentsTotal' => compsTotal
                };
            }

            String  successStr = extractTagValue(body, 'success');
            Boolean isSuccess  = successStr == 'true';

            Integer testsRun    = 0;
            Integer testsFailed = 0;
            try {
                String tr = extractTagValue(body, 'numTestsRun');
                String tf = extractTagValue(body, 'numFailures');
                if (tr != null) testsRun    = Integer.valueOf(tr);
                if (tf != null) testsFailed = Integer.valueOf(tf);
            } catch (Exception ex) {}

            if (testsFailed > 0) isSuccess = false;

            // Component failures parse karo
            List<Map<String, String>> errors = new List<Map<String, String>>();
            String bodyWork = body;
            while (bodyWork.contains('<componentFailures>')) {
                Integer s = bodyWork.indexOf('<componentFailures>');
                Integer e = bodyWork.indexOf('</componentFailures>');
                if (s < 0 || e < 0) break;
                String block    = bodyWork.substring(s, e + '</componentFailures>'.length());
                String fileName = extractTagValue(block, 'fileName');
                String problem  = extractTagValue(block, 'problem');
                String lineNum  = extractTagValue(block, 'lineNumber');
                String probType = extractTagValue(block, 'problemType');
                if (String.isNotBlank(problem)) {
                    errors.add(new Map<String, String>{
                        'fileName'    => fileName != null ? fileName : '',
                        'problem'     => problem,
                        'lineNumber'  => lineNum  != null ? lineNum  : '',
                        'problemType' => probType != null ? probType : 'Error'
                    });
                }
                bodyWork = bodyWork.substring(e + '</componentFailures>'.length());
            }

            // Test failures parse karo
            List<Map<String, String>> testFailures = new List<Map<String, String>>();
            String bodyWork2 = body;
            while (bodyWork2.contains('<failures>')) {
                Integer s2 = bodyWork2.indexOf('<failures>');
                Integer e2 = bodyWork2.indexOf('</failures>');
                if (s2 < 0 || e2 < 0) break;
                String block2     = bodyWork2.substring(s2, e2 + '</failures>'.length());
                String testName   = extractTagValue(block2, 'methodName');
                String className  = extractTagValue(block2, 'name');
                String testMsg    = extractTagValue(block2, 'message');
                String stackTrace = extractTagValue(block2, 'stackTrace');
                if (String.isNotBlank(testMsg)) {
                    testFailures.add(new Map<String, String>{
                        'testName'   => testName   != null ? testName   : '',
                        'className'  => className  != null ? className  : '',
                        'message'    => testMsg,
                        'stackTrace' => stackTrace != null ? stackTrace : ''
                    });
                }
                bodyWork2 = bodyWork2.substring(e2 + '</failures>'.length());
            }

            if (!testFailures.isEmpty() && errors.isEmpty()) {
                for (Map<String, String> tf : testFailures) {
                    errors.add(new Map<String, String>{
                        'fileName'    => tf.get('className') + '.' + tf.get('testName'),
                        'problem'     => tf.get('message'),
                        'lineNumber'  => '',
                        'problemType' => 'TestFailure'
                    });
                }
            }

            return new Map<String, Object>{
                'status'       => isSuccess ? 'Passed' : 'Failed',
                'success'      => isSuccess,
                'errors'       => errors,
                'testFailures' => testFailures,
                'testsRun'     => testsRun,
                'testsFailed'  => testsFailed,
                'testsPassed'  => testsRun - testsFailed
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('checkValidateStatus: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // SAVE PROMOTION (update existing record after validation)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String savePromotion(
            String  promotionId,
            String  userStoryId,
            String  status,
            String  featureBranch,
            String  promotionBranch,
            String  commitSha,
            Integer totalComponents,
            Integer testsRun,
            Integer testsPassed,
            Integer testsFailed,
            String  errorMessage,
            String  jobId) {
        try {
            Promotion__c promo;
            Boolean isValidated = (status == 'Validated');

            if (String.isNotBlank(promotionId)) {
                promo = [SELECT Id FROM Promotion__c WHERE Id = :promotionId LIMIT 1];
                promo.Status__c           = status;
                promo.Feature_Branch__c   = featureBranch;
                promo.Promotion_Branch__c = promotionBranch;
                promo.Commit_SHA__c       = commitSha;
                promo.Total_Components__c = totalComponents;
                promo.Tests_Run__c        = testsRun;
                promo.Tests_Passed__c     = testsPassed;
                promo.Tests_Failed__c     = testsFailed;
                promo.Validation_Error__c = errorMessage;
                promo.Job_ID__c           = jobId;
                if (isValidated) {
                    promo.Validated_By__c = UserInfo.getUserId();
                    promo.Validated_At__c = DateTime.now();
                }
                update promo;
            } else {
                promo = new Promotion__c(
                    User_Story__c         = userStoryId,
                    Status__c             = status,
                    Feature_Branch__c     = featureBranch,
                    Promotion_Branch__c   = promotionBranch,
                    Commit_SHA__c         = commitSha,
                    Total_Components__c   = totalComponents,
                    Tests_Run__c          = testsRun,
                    Tests_Passed__c       = testsPassed,
                    Tests_Failed__c       = testsFailed,
                    Validation_Error__c   = errorMessage,
                    Job_ID__c             = jobId,
                    Validated_By__c       = isValidated ? UserInfo.getUserId() : null,
                    Validated_At__c       = isValidated ? DateTime.now()       : null
                );
                insert promo;
            }

            insert new Promotion_History__c(
                Promotion__c        = promo.Id,
                Action__c           = 'Validated',
                Status__c           = isValidated ? 'Success' : 'Failed',
                Feature_Branch__c   = featureBranch,
                Branch_Name__c      = promotionBranch,
                Commit_SHA__c       = commitSha,
                Components_Count__c = totalComponents,
                Performed_By__c     = UserInfo.getUserId(),
                Performed_At__c     = DateTime.now(),
                Error_Message__c    = errorMessage
            );

            return promo.Id;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('savePromotion: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET PROMOTION DETAILS (for PromotionDeploy LWC)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getPromotionDetails(String promotionId) {
        try {
            Promotion__c promo = [
                SELECT Id, Name, Status__c,
                       Feature_Branch__c, Promotion_Branch__c,
                       Validated_At__c, Deployed_At__c,
                       Validated_By__r.Name, Deployed_By__r.Name,
                       Total_Components__c, Tests_Run__c,
                       Tests_Passed__c, Tests_Failed__c,
                       Validation_Error__c, Commit_SHA__c,
                       User_Story__c, User_Story__r.Name,
                       Job_ID__c
                FROM Promotion__c
                WHERE Id = :promotionId
                LIMIT 1
            ];

            return new Map<String, Object>{
                'id'              => promo.Id,
                'name'            => promo.Name,
                'status'          => promo.Status__c,
                'featureBranch'   => promo.Feature_Branch__c,
                'promotionBranch' => promo.Promotion_Branch__c,
                'validatedAt'     => promo.Validated_At__c != null ? String.valueOf(promo.Validated_At__c) : '',
                'deployedAt'      => promo.Deployed_At__c  != null ? String.valueOf(promo.Deployed_At__c)  : '',
                'validatedBy'     => promo.Validated_By__r != null ? promo.Validated_By__r.Name : '',
                'deployedBy'      => promo.Deployed_By__r  != null ? promo.Deployed_By__r.Name  : '',
                'totalComponents' => promo.Total_Components__c,
                'testsRun'        => promo.Tests_Run__c,
                'testsPassed'     => promo.Tests_Passed__c,
                'testsFailed'     => promo.Tests_Failed__c,
                'validationError' => promo.Validation_Error__c,
                'commitSha'       => promo.Commit_SHA__c,
                'jobId'           => promo.Job_ID__c,
                'userStoryId'     => promo.User_Story__c,
                'userStoryName'   => promo.User_Story__r != null ? promo.User_Story__r.Name : '',
                'canDeploy'       => promo.Status__c == 'Validated'
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getPromotionDetails: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // DEPLOY — Mark promotion record as Deployed
    // (Promotion branch already created during validate step)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String deployPromotion(String promotionId) {
        try {
            Promotion__c promo = [
                SELECT Id, Feature_Branch__c, Promotion_Branch__c, Commit_SHA__c
                FROM Promotion__c
                WHERE Id = :promotionId
                LIMIT 1
            ];

            if (String.isBlank(promo.Promotion_Branch__c)) {
                throw createAuraException('Promotion branch not found on this record. Please validate again.');
            }

            promo.Status__c      = 'Deployed';
            promo.Deployed_By__c = UserInfo.getUserId();
            promo.Deployed_At__c = DateTime.now();
            update promo;

            insert new Promotion_History__c(
                Promotion__c      = promo.Id,
                Action__c         = 'Deployed',
                Status__c         = 'Success',
                Feature_Branch__c = promo.Feature_Branch__c,
                Branch_Name__c    = promo.Promotion_Branch__c,
                Commit_SHA__c     = promo.Commit_SHA__c,
                Performed_By__c   = UserInfo.getUserId(),
                Performed_At__c   = DateTime.now()
            );

            return promo.Promotion_Branch__c;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            try {
                List<Promotion__c> promos = [SELECT Id FROM Promotion__c WHERE Id = :promotionId LIMIT 1];
                if (!promos.isEmpty()) {
                    promos[0].Status__c = 'Deploy Failed';
                    update promos[0];
                    insert new Promotion_History__c(
                        Promotion__c     = promotionId,
                        Action__c        = 'Deployed',
                        Status__c        = 'Failed',
                        Performed_By__c  = UserInfo.getUserId(),
                        Performed_At__c  = DateTime.now(),
                        Error_Message__c = e.getMessage()
                    );
                }
            } catch (Exception ex) {}
            throw createAuraException('deployPromotion: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // UTILITIES
    // ═══════════════════════════════════════════════════════════
    private static AuraHandledException createAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static String extractTagValue(String xml, String tagName) {
        if (String.isBlank(xml)) return null;
        Integer s = xml.indexOf('<' + tagName + '>');
        Integer e = xml.indexOf('</' + tagName + '>');
        if (s >= 0 && e > s) return xml.substring(s + tagName.length() + 2, e).trim();
        Pattern p = Pattern.compile('<[^:>]+:' + tagName + '[^>]*>([^<]*)<');
        Matcher m = p.matcher(xml);
        return m.find() ? m.group(1).trim() : null;
    }
}