grails {
    plugin {
        springsecurity {
            saml {
                // Activate SAML integration with IriusRisk
                active = true

                // Base to generate URLs for this server. For example: https://my-server:443/app. The public address your server will be accessed from should be used here.
                entityBaseUrl = 'https://your-instance.iriusrisk.com'

                entityId = "iriusrisk-app"

                // Set Custom entity id for the instance where it is different from the default - "iriusrisk-app".
                // entityId = "custom-entity-id"
                
                // Mapping User fields to SAML fields, e.g: [firstName: givenName], firstName is the user field in IriusRisk (do not change), givenName is SAML field
                userAttributeMappings = [
                    'username' : 'email',
                    'firstName': 'firstName',
                    'lastName' : 'lastName',
                    'email' : 'email'
                ]
                
                // SAML assertion attribute that holds returned group membership data
                userGroupAttribute = 'memberOf'

                // Custom Values, mapping Okta Groups GUIDs (used as keys in the configuration map userGroupToRoleMapping) to Irius RoleGroup names (used as values in the configuration map userGroupToRoleMapping)
                userGroupToRoleMapping = [
                    'Your_keycloak_group':'ROLE_TEST_ONLY',
                    'Your_keycloak_group':'ROLE_ADMIN',
                    'Your_keycloak_group':'ROLE_PORTFOLIO_VIEW',
                    'Your_keycloak_group':'ROLE_DEVELOPER',
                    'Your_keycloak_group':'ROLE_FULL_ACCESS_USER',
                    'Your_keycloak_group':'ROLE_MANAGE_USERS_BU',
                    'Your_keycloak_group':'ROLE_RISK_MANAGER',
                    'Your_keycloak_group':'ROLE_RULES_EDITOR',
                    'Your_keycloak_group':'ROLE_TEMPLATE_EDITOR',
                    'Your_keycloak_group':'ROLE_REQUIREMENTS_MANAGE',
                    'Your_keycloak_group':'ROLE_TESTER',
                    'Your_keycloak_group':'ROLE_QUESTIONNAIRE_ONLY',
                    'Your_keycloak_group':'ROLE_LIBRARY_EDITOR'
                    
                ]

                // If there is no information about roles in the SAML Response, IriusRisk will use this property to assign a default role to the User
                defaultRole = 'ROLE_DEVELOPER'

                // SAML assertion attribute that holds returned business unit data
                // businessUnitsAttribute = 'department'

                // Custom Values, mapping group names with (used as keys in the configuration map businessUnitsMapping) to Irius business units refs (used as values in the configuration map businessUnitsMapping)
                // businessUnitsMapping = [
                //    'Your_keycloak_group': 'testers',
                //    'Your_keycloak_group': 'managers',
                //    'Your_keycloak_group': 'developers'
                // ]
                // If there is no information about business units in the SAML Response, IriusRisk will use this property to assign a default business unit to the User
                // defaultBusinessUnit = 'testers'

                signatureAlgorithm = 'rsa-sha256'
                digestAlgorithm = 'sha256'
                
                metadata {
                    // Relative URL in IriusRisk to download sp.xml metadata
                    url = '/saml/metadata'
                    // Provider to be used from the configuration map providers
                    defaultIdp = 'keycloak'
                    // Configuration map providers, using the name of the provider as key and the file system path to the xml descriptor file from Azure
                    providers = [ keycloak :'/etc/irius/idp.xml']
                    idp {
                        title = 'keycloak' // SAML login caption. This will read "Login With keycloak" Change as when necessary 
                    }
                    sp {
                        file = '/etc/irius/sp.xml'
                        defaults = [
                            // alias should correspond to your entity id
                            alias: 'iriusrisk-app',
                            signingKey: 'iriusrisk-sp',
                            encryptionKey: 'iriusrisk-sp',
                            tlsKey: 'iriusrisk-sp',
                        ]
                    }
                }

                keyManager {
                    storeFile = 'file:/etc/irius/iriusrisk-sp.jks'
                    storePass = System.getenv('KEYSTORE_PASSWORD')
                    passwords = [
                        'iriusrisk-sp': (System.getenv('KEY_ALIAS_PASSWORD'))
                    ]
                    defaultKey = 'iriusrisk-sp'
                }
            }
        }
    }
}