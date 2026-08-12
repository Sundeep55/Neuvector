1. i have removed the validate.yaml as it is failing our internal chart generation pipeline. you can ignore updating it moving forward.
2. I have created for all 3 envs dev, qa and qa man, crts with all 4 SAN, UI, api, adapter, fed regalrdless of usage
3. in dev we have a standalone cluster but i have enabled the registry adapter in dev, and wanted to expose the adapter using an URL and hook to our central harbor instace which is internet connected so that we can test it. so first thing i did was first created an adapterAuth secret using a new user creds in harbor and updated the adapter section like below.
   ```
    adapter:
      enabled: true
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 1Gi
      certificate:
        secret: dcs-neuvector-external-certs
        keyFile: tls.key
        pemFile: tls.crt
      harbor:
        protocol: https
        secretName: dcs-neuvector-adapter-auth
      route:
        enabled: true
        termination: passthrough
        host: NV-adapter.{{globalVars.cluster.baseDomain}}
   ```
   the issue i see now is, firstly yesterday onlu manager and api endpoints in browsers were using the corect cert which we provided, but not adapter, it was showing insecure, but today i guess it detected the right cert and showing secure in browser. next, in dev since we exposed the adapter as a route, i tried to hook the route into the harbor (running in another cluster not managed by us to check) by clicking on Interagation Services > Scanners > Add Scanner> Name: neuvector-dev, endpoint https://neuvector.apps.ocp-dev.x.com, auth: none (as of now) and i see this error "Ping: registration neuvector-dev:https://neuvector.apps.ocp-dev.x.co is unreachable", i tried to update the endpoint with https://neuvector.apps.ocp-dev.x.com/endpoint but same error. I can confirm that there are no network policies in both the namesapces, namesapce where harbor is running and where neuvector is running.
4. These are the logs if i try to reach the adapter endpoint via broswer trying different things out
  ```
  2026-08-11T14:05:51.906|INFO|SAP|main.main: START - version=v0.2.9
  2026-08-11T14:06:27.577|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/
  2026-08-11T14:09:10.31 |WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/
  2026-08-11T14:10:37.845|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  2026-08-11T14:16:40.108|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  2026-08-11T14:19:08.956|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/endpoint
  2026-08-12T07:38:40.151|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  2026-08-12T07:38:40.385|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/favicon.ico
  2026-08-12T07:44:10.4 |WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/
  2026-08-12T07:44:49.834|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  2026-08-12T07:45:08.856|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/endpoint
  2026-08-12T07:45:49.467|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  2026-08-12T07:45:55.66 |WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v2/metadata
  ```
5. So i continued to deploy things in qa and qa managed, but this time since qa has its own harbor in hub, so did not expose the rouite. so basically this is the adapter config for hub
  ```
      adapter:
        enabled: true
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 1Gi
  
        harbor:
          protocol: https
          secretName: dcs-neuvector-adapter-auth
  ```
  hoping since it is not using route and both harbor and neuvector stay in same cluster, the cluster service hostname should work, but when i add the the qa hub harbor i see this error "Ping: registration test:https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local is unreachable" and i can confirm again that the both the namespaes do not have any network policies blocking. i have also tried to do an oc port forward this service to my local laptop and opened the endpoint on localhost 9443, it initially said "404 page not found" but when i tried with different suffixes i see this error in pod logs.
  ```
  2026-08-12T08:07:46.518|INFO|SAP|main.main: START - version=v0.2.9
  2026/08/12 08:10:33 http: TLS handshake error from [::1]:51496: client sent an HTTP request to an HTTPS server
  2026/08/12 08:10:48 http: TLS handshake error from [::1]:48582: remote error: tls: unknown certificate
  2026/08/12 08:10:51 http: TLS handshake error from [::1]:48596: remote error: tls: unknown certificate
  2026/08/12 08:10:53 http: TLS handshake error from [::1]:48602: remote error: tls: unknown certificate
  2026-08-12T08:10:54.008|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/
  2026-08-12T08:10:54.239|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/favicon.ico
  2026-08-12T08:11:03.233|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/endpoint
  2026-08-12T08:11:15.442|WARN|SAP|server.unhandled: Unhandled HTTP Endpoint - endpoint=/api/v1/metadata
  ```
for the above issue, below are different logs in registry core pod, i tried with skip certificate verification option with and without so all logs below
```
2026-08-12T08:10:05Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter:9443/api/v1/metadata": Forbidden" requestID="554b8bed-6afb-4d78-903e-e77daebb1f08"]: failed to ping scanner
2026-08-12T08:10:05Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter:9443/api/v1/metadata\": Forbidden"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167

2026-08-12T08:07:37Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/endpoint/api/v1/metadata": context deadline exceeded (Client.Timeout exceeded while awaiting headers)" requestID="dc315c55-d108-43a5-b4b7-28bb43f7241f"]: failed to ping scanner
2026-08-12T08:07:37Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/endpoint/api/v1/metadata\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP

2026-08-12T08:07:28Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "http://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/api/v1/metadata": context deadline exceeded (Client.Timeout exceeded while awaiting headers)" requestID="a5e15200-ea31-4138-9aa8-8ff3f1637556"]: failed to ping scanner
2026-08-12T08:07:28Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"http://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/api/v1/metadata\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP

2026-08-12T08:07:21Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/api/v1/metadata": context deadline exceeded (Client.Timeout exceeded while awaiting headers)" requestID="14963375-cc33-4185-b8e3-6c2d31a33d8c"]: failed to ping scanner
2026-08-12T08:07:21Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local/api/v1/metadata\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167

2026-08-12T08:07:12Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/api/v1/metadata": tls: failed to verify certificate: x509: certificate signed by unknown authority" requestID="e7acf06c-b5f6-4405-93db-41c014c2b43e"]: failed to ping scanner
2026-08-12T08:07:12Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/api/v1/metadata\": tls: failed to verify certificate: x509: certificate signed by unknown authority"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167

2026-08-12T08:07:06Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: general response handler: invalid character 'C' looking for beginning of value" requestID="36a4e01d-5f7d-49fe-afe3-3e72b53cc5a6"]: failed to ping scanner
2026-08-12T08:07:06Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: general response handler: invalid character 'C' looking for beginning of value"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP

2026-08-12T07:49:31Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint/api/v1/metadata": tls: failed to verify certificate: x509: certificate signed by unknown authority" requestID="50661145-848e-4b19-8386-44d116c2960d"]: failed to ping scanner
2026-08-12T07:49:31Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint/api/v1/metadata\": tls: failed to verify certificate: x509: certificate signed by unknown authority"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP

2026-08-12T07:05:26Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/api/v1/metadata": tls: failed to verify certificate: x509: certificate signed by unknown authority" requestID="d1866d56-a9ea-4a4e-846b-31604f1a4c30"]: failed to ping scanner
2026-08-12T07:05:26Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/api/v1/metadata\": tls: failed to verify certificate: x509: certificate signed by unknown authority"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP

2026-08-12T08:20:50Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint/api/v1/metadata": tls: failed to verify certificate: x509: certificate signed by unknown authority" requestID="6a51d831-1713-473f-b229-1f4aa037bc93"]: failed to ping scanner
2026-08-12T08:20:50Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint/api/v1/metadata\": tls: failed to verify certificate: x509: certificate signed by unknown authority"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/operation.go:17, github.com/go-openapi/runtime/middleware.(*Context).RoutesHandler.NewOperationExecutor.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/router.go:67, github.com/go-openapi/runtime/middleware.NewRouter.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/ui_options.go:167, github.com/go-openapi/runtime/middleware.Redoc.serveUI.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/spec.go:61, github.com/go-openapi/runtime/middleware.Spec.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/apiversion/api_version.go:29, github.com/goharbor/harbor/src/server/v2.0/route.RegisterRoutes.Middleware.func1.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/router/router.go:92, github.com/goharbor/harbor/src/server/router.(*Route).Handler.func1
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/router.go:1149, github.com/beego/beego/v2/server/web.(*ControllerRegister).serveHttp
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/filter.go:83, github.com/beego/beego/v2/server/web.(*FilterRouter).filter
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/router.go:1002, github.com/beego/beego/v2/server/web.(*ControllerRegister).ServeHTTP
/harbor/src/server/middleware/readonly/readonly.go:77, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.func20
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.New.func22.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/security/security.go:75, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.UnauthorizedMiddleware.func10
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.UnauthorizedMiddleware.New.func19.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/log/log.go:83, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func9
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func18.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/security/security.go:62, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func8
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func17.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/artifactinfo/artifact_info.go:62, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func7.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/transaction/transaction.go:60, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func6.1
/harbor/src/lib/orm/orm.go:157, github.com/goharbor/harbor/src/lib/orm.WithTransaction.func1
/harbor/src/server/middleware/transaction/transaction.go:69, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func6
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func16.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/notification/notification.go:31, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func5
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func15.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/orm/orm.go:54, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.func14
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.New.func21.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/csrf/csrf.go:62, github.com/goharbor/harbor/src/server/middleware/csrf.Middleware.func2.attach.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/gorilla/csrf@v1.7.2/csrf.go:306, github.com/gorilla/csrf.(*csrf).ServeHTTP
/harbor/src/server/middleware/csrf/csrf.go:89, github.com/goharbor/harbor/src/server/middleware/csrf.Middleware.func2
2026-08-12T08:20:58Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 53216 for permission evaluator, error: project 53216 not found
2026-08-12T08:21:05Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 51556 for permission evaluator, error: project 51556 not found
2026-08-12T08:21:07Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 51556 for permission evaluator, error: project 51556 not found
2026-08-12T08:21:08Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 51556 for permission evaluator, error: project 51556 not found
2026-08-12T08:21:27Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 53216 for permission evaluator, error: project 53216 not found
2026-08-12T08:21:34Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 164106 for permission evaluator, error: project 164106 not found
2026-08-12T08:21:34Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 53167 for permission evaluator, error: project 53167 not found
2026-08-12T08:21:37Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 164106 for permission evaluator, error: project 164106 not found
2026-08-12T08:21:38Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 164106 for permission evaluator, error: project 164106 not found
2026-08-12T08:21:43Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter:9443/endpoint/api/v1/metadata": Forbidden" requestID="5598b188-c555-4427-8782-e80535f9e0a9"]: failed to ping scanner
2026-08-12T08:21:43Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter:9443/endpoint/api/v1/metadata\": Forbidden"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
/harbor/src/server/v2.0/restapi/operations/harbor_api.go:1968, github.com/goharbor/harbor/src/server/v2.0/restapi/operations.(*HarborAPI).initHandlerCache.(*HarborAPI).handler.func167
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/operation.go:17, github.com/go-openapi/runtime/middleware.(*Context).RoutesHandler.NewOperationExecutor.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/router.go:67, github.com/go-openapi/runtime/middleware.NewRouter.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/ui_options.go:167, github.com/go-openapi/runtime/middleware.Redoc.serveUI.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/go-openapi/runtime@v0.29.2/middleware/spec.go:61, github.com/go-openapi/runtime/middleware.Spec.func1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/apiversion/api_version.go:29, github.com/goharbor/harbor/src/server/v2.0/route.RegisterRoutes.Middleware.func1.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/router/router.go:92, github.com/goharbor/harbor/src/server/router.(*Route).Handler.func1
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/router.go:1149, github.com/beego/beego/v2/server/web.(*ControllerRegister).serveHttp
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/filter.go:83, github.com/beego/beego/v2/server/web.(*FilterRouter).filter
/go/pkg/mod/github.com/beego/beego/v2@v2.3.10/server/web/router.go:1002, github.com/beego/beego/v2/server/web.(*ControllerRegister).ServeHTTP
/harbor/src/server/middleware/readonly/readonly.go:77, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.func20
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.New.func22.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/security/security.go:75, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.UnauthorizedMiddleware.func10
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.UnauthorizedMiddleware.New.func19.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/log/log.go:83, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func9
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func18.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/security/security.go:62, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func8
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func17.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/artifactinfo/artifact_info.go:62, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func7.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/transaction/transaction.go:60, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func6.1
/harbor/src/lib/orm/orm.go:157, github.com/goharbor/harbor/src/lib/orm.WithTransaction.func1
/harbor/src/server/middleware/transaction/transaction.go:69, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func6
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func16.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/notification/notification.go:31, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.func5
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.New.func15.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/orm/orm.go:54, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.func14
/harbor/src/server/middleware/middleware.go:57, github.com/goharbor/harbor/src/core/middlewares.MiddleWares.Middleware.MiddlewareWithConfig.New.func21.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/harbor/src/server/middleware/csrf/csrf.go:62, github.com/goharbor/harbor/src/server/middleware/csrf.Middleware.func2.attach.1
/usr/local/go/src/net/http/server.go:2322, net/http.HandlerFunc.ServeHTTP
/go/pkg/mod/github.com/gorilla/csrf@v1.7.2/csrf.go:306, github.com/gorilla/csrf.(*csrf).ServeHTTP
/harbor/src/server/middleware/csrf/csrf.go:89, github.com/goharbor/harbor/src/server/middleware/csrf.Middleware.func2
2026-08-12T08:21:50Z [WARNING] [/common/rbac/project/evaluator.go:80]: Failed to get info of project 53216 for permission evaluator, error: project 53216 not found
2026-08-12T08:21:53Z [ERROR] [/controller/scanner/base_controller.go:323][error="v1 client: get metadata: Get "https://neuvector-service-registry-adapter/endpoint/api/v1/metadata": Forbidden" requestID="99363a5f-8fd4-4090-b877-9d087d1fe469"]: failed to ping scanner
2026-08-12T08:21:53Z [ERROR] [/lib/http/error.go:58]: {"errors":[{"code":"UNKNOWN","message":"scanner controller: ping: v1 client: get metadata: Get \"https://neuvector-service-registry-adapter/endpoint/api/v1/metadata\": Forbidden"}]} 
/harbor/src/controller/scanner/base_controller.go:325, github.com/goharbor/harbor/src/controller/scanner.(*basicController).Ping
/harbor/src/server/v2.0/handler/scanner.go:186, github.com/goharbor/harbor/src/server/v2.0/handler.(*scannerAPI).PingScanner
/harbor/src/server/v2.0/restapi/configure_harbor.go:3246, github.com/goharbor/harbor/src/server/v2.0/restapi.HandlerAPI.func168
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:19, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.PingScannerHandlerFunc.Handle
/harbor/src/server/v2.0/restapi/operations/scanner/ping_scanner.go:68, github.com/goharbor/harbor/src/server/v2.0/restapi/operations/scanner.(*PingScanner).ServeHTTP
```
