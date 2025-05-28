grails {
    plugin {
        springsecurity {
            saml {
                entityBaseUrl = 'https://your-instance.iriusrisk.com';
                userAttributeMappings = [
                    'username' : 'http://schemas.auth0.com/email';,
                    'firstName': 'http://schemas.auth0.com/nickname';,
                    'lastName' : 'http://schemas.auth0.com/nickname';,
                    'email'    : 'http://schemas.auth0.com/email';
                ]
                defaultRole = 'ROLE_DEVELOPER'

                // contextProvider {
                //     providerClass = 'SAMLContextProviderLB'
                //     scheme = 'https'
                //     serverName = 'your external hostname'
                //     serverPort = 443
                //     includeServerPortInRequestURL = false
                //     contextPath = '/MicroStrategyLibrary'
                // }
            }
        }
    }
}