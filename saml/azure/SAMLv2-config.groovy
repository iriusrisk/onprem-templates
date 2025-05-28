grails {
    plugin {
        springsecurity {
            saml {
                // Activate SAML integration with IriusRisk
                active = true

                // Base to generate URLs for this server. For example: https://my-server:443/app. The public address your server will be accessed from should be used here.
                entityBaseUrl = 'https://your-instance.iriusrisk.com';

                // Set Custom entity id for the instance where it is different from the default - "iriusrisk-sp".
                // entityId = "custom-entity-id"

                // Informational -- Default entity id is set to iriusrisk-sp by default, if default, no need to uncomment below.
                // entityId = "iriusrisk-sp"

               // Mapping User fields to SAML fields, e.g: [firstName: givenName], firstName is the user field in IriusRisk (do not change), givenName is SAML field 
                userAttributeMappings = [
                    'username' : 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress';,
                    'firstName': 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname';,
                    'lastName' : 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname';,
                    'email'    : 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress';
                ]

                // SAML assertion attribute that holds returned group membership data
                userGroupAttribute = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups';

                // Custom Values, mapping Azure Groups GUIDs (used as keys in the configuration map userGroupToRoleMapping) to Irius RoleGroup names (used as values in the configuration map userGroupToRoleMapping)
                userGroupToRoleMapping = [
                    'Your_Azure_Group_Ids':'ROLE_TEST_ONLY',
                    'Your_Azure_Group_Ids':'ROLE_ADMIN',
                    'Your_Azure_Group_Ids':'ROLE_PORTFOLIO_VIEW',
                    'Your_Azure_Group_Ids':'ROLE_DEVELOPER',
                    'vjvIVt2Y-1m9w-YAHA-kfNf-TvrvQjfDV5SI':'ROLE_FULL_ACCESS_USER',
                    'cVKF1BWo-xOnx-kqyb-jS0N-JCeioBU9QfzY':'ROLE_MANAGE_USERS_BU',
                    'lGqiGVlK-wftf-sbNJ-uft0-bpGya43Tu1Lu':'ROLE_RISK_MANAGER',
                    'xQ2fb3qR-IApK-ByIz-gTFr-bueb8ieVSwn5':'ROLE_RULES_EDITOR',
                    'yoHoV6OL-qfTz-6nAa-WOI2-JKl0IyqnIJDm':'ROLE_TEMPLATE_EDITOR',
                    'Spg72Xwt-O3Oq-au0x-SAFk-U86mCDbfYJ3K':'ROLE_REQUIREMENTS_MANAGE',
                    'Your_Azure_Group_Ids':'ROLE_TESTER',
                    'Your_Azure_Group_Ids':'ROLE_QUESTIONNAIRE_ONLY',
                    'Your_Azure_Group_Ids':'ROLE_LIBRARY_EDITOR'
                ]

                // If there is no information about roles in the SAML Response, IriusRisk will use this property to assign a default role to the User 
                defaultRole = 'ROLE_DEVELOPER'

                // SAML assertion attribute that holds returned business unit data
                // businessUnitsAttribute = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups';

                // Custom Values, mapping group names with (used as keys in the configuration map businessUnitsMapping) to Irius business units refs (used as values in the configuration map businessUnitsMapping)
                // businessUnitsMapping = [
                // '77b7b701-7388-3207-ga3e-1891abec1951':'testers',
                // '823c072c-2e41-4ddf-ea28-db00a971e888':'managers',
                // '1fae5bb2-3c73-43d1-97fc-a2dba22bbc07':'developers'
                // ]

                // If there is no information about business units in the SAML Response, IriusRisk will use this property to assign a default business unit to the User
                // defaultBusinessUnit = 'testers'

                metadata {
                    // Relative URL in IriusRisk to download sp.xml metadata
                    url = '/saml/metadata'
                    // Provider to be used from the configuration map providers
                    defaultIdp = 'azure'
                    // Configuration map providers, using the name of the provider as key and the file system path to the xml descriptor file from Azure
                    providers = [ azure :'/etc/irius/idp.xml']
                    idp {
                        title = 'Azure' // SAML login caption. This will read "Login With Azure" Change as when necessary 
                    }
                    sp {
                        file = '/etc/irius/sp.xml'
                        defaults = [
                            // alias should correspond to your entity id
                            alias: 'iriusrisk-sp',
                            signingKey: 'iriusrisk-sp',
                            encryptionKey: 'iriusrisk-sp',
                            tlsKey: 'iriusrisk-sp',
                        ]
                    }
                }
                keyManager {
                    storeFile = 'file:/etc/irius/iriusrisk-sp.jks'
                    storePass = 'changeit'
                    passwords = [ 'iriusrisk-sp': 'changeit' ]
                    defaultKey = 'iriusrisk-sp'
                }

                // contextProvider {
                //     providerClass = 'SAMLContextProviderLB'
                //     scheme = 'https'
                //     serverName = 'your external hostname'
                //     serverPort = 443
                //     includeServerPortInRequestURL = false
                //     contextPath ='/MicroStrategyLibrary'
                // }
            }
        }
    }
}