import 'package:http_client/console.dart';

import 'src/http_transport.dart';

export 'elastic_client.dart';
export 'src/http_transport.dart';

class ConsoleHttpTransport extends HttpTransport {
  ConsoleHttpTransport(
    Uri uri, {
    BasicAuth basicAuth,
    Duration timeout,
  }) : super(
          new ConsoleClient(),
          uri,
          basicAuth: basicAuth,
          timeout: timeout,
        );
}
