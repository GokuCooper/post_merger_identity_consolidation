# Decision log

Every choice that a reviewer or interviewer might ask "why?" about. One line each, filled in as you go.

| Day | Decision | Options considered | Why this one | Revisit when |
| --- | --- | --- | --- | --- |
| 1 | Forest wide authentication on the trust | Forest wide, selective | Lab needs broad access to test; production would start selective | Before any real merger |
| 1 | SID filtering left on | On, off | Safe default until migration needs it | Day 3 |
| 2 | Custom schema attribute dknSourceCompany | New attribute, reuse extensionAttribute, use company field | |  |
| 3 | SID filtering turned off on the trust | | Needed so SID history works during cutover | After share re-permissioning |
| 3 | Name collision rule: append _pt | Rename with suffix, replace, skip | |  |
| 4 | Password hash sync | PHS, pass through auth, federation | |  |
| 4 | Service accounts excluded from sync by OU filter | | Non human accounts have no business in the cloud directory |  |
| 5 | Correlate on employeeID, not account name | | Names changed during migration (jsmith to jsmith_pt) |  |
| 5 | Old CRM access retired | Keep with owner, retire | No approver, no AD group |  |
| 6 | gMSA for reports, CyberArk for SQL and backup | | |  |
| 7 | Federated credential locked to one environment | Branch subject, environment subject, immutable subject | |  |
