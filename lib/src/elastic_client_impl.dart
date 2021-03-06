import 'dart:async';
import 'dart:convert' as convert;

import 'transport.dart';

class Doc {
  final String index;
  final String type;
  final String id;
  final Map<String, dynamic> doc;
  final double score;
  final List<dynamic> sort;
  final Map<String, dynamic> highlight;

  Doc(this.id, this.doc, {this.index, this.type, this.score, this.sort, this.highlight});

  Map toMap() {
    final map = {
      '_index': index,
      '_type': type,
      '_id': id,
      '_score': score,
      'doc': doc,
      'sort': sort,
      'highlight': highlight,
    };
    map.removeWhere((k, v) => v == null);
    return map;
  }
}

class Client {
  final Transport _transport;

  Client(this._transport);

  Future<bool> indexExists(String index) async {
    final rs = await _transport.send(new Request('HEAD', [index]));
    return rs.statusCode == 200;
  }

  Future updateIndex(String index, Map<String, dynamic> content) async {
    Response response = await _transport.send(new Request('PUT', [index], bodyMap: content));
    if(response.statusCode != 200) {
      throw "error updating index: ${response.statusCode} ${response.body}";
    }
  }

  Future<void> copyIndex(String source, String target) async {
    await _transport.send(
      Request(
        "POST",
        ["_reindex"],
        bodyMap: {
          "source": {"index": source},
          "dest": {"index": target}
        },
        params: {"refresh": "true"},
      ),
    );
  }

  Future flushIndex(String index) async {
    await _transport.send(new Request('POST', [index, '_flush'],
        params: {'wait_if_ongoing': 'true'}));
  }

  Future<bool> deleteIndex(String index) async {
    final rs = await _transport.send(new Request('DELETE', [index]));
    return rs.statusCode == 200;
  }

  Future<bool> updateDoc(String index, String type, String id, Map<String, dynamic> doc) async {
    final pathSegments = [index, type];
    if (id != null) pathSegments.add(id);
    final rs =
    await _transport.send(new Request('POST', pathSegments, bodyMap: doc));
    return rs.statusCode == 200 || rs.statusCode == 201;
  }

  Future<bool> updateDocs(String index, String type, List<Doc> docs,
      {int batchSize = 100, Map<String, String> params}) async {
    final pathSegments = [index, type, '_bulk']..removeWhere((v) => v == null);
    for (int start = 0; start < docs.length;) {
      final sub = docs.skip(start).take(batchSize).toList();
      final lines = sub
          .map((doc) =>
      [
        {
          'index': {
            '_index': doc.index,
            '_type': doc.type,
            '_id': doc.id
          }
            ..removeWhere((k, v) => v == null)
        },
        doc.doc,
      ])
          .expand((list) => list)
          .map(convert.json.encode)
          .map((s) => '$s\n')
          .join();
      final rs = await _transport
          .send(new Request('POST', pathSegments, bodyText: lines, params: params));
      if (rs.statusCode != 200) {
        throw new Exception(
            'Unable to update batch starting with $start. ${rs.statusCode} ${rs.body}');
      }
      start += sub.length;
    }
    return true;
  }

  Future<int> deleteDoc(String index, String type, String id) async {
    final rs = await _transport.send(new Request('DELETE', [index, type, id]));
    return rs.statusCode == 200 ? 1 : 0;
  }

  Future<int> deleteDocs(String index, Map query, {Map<String, String> params}) async {
    final rs = await _transport.send(new Request(
        'POST', [index, '_delete_by_query'],
        bodyMap: {'query': query}, params: params));
    if (rs.statusCode != 200) return 0;
    return rs.bodyAsMap['deleted'] as int ?? 0;
  }

  Future<SearchResult> search(String index, String type, Map query,
      {int offset,
        int limit,
        @Deprecated("Use 'source' instead") bool fetchSource = false,
        dynamic source,
        Map suggest,
        List<Map> sort,
        Map<String, String> params,
        Map<String, dynamic> highlight}) async {
    final path = [index, type, '_search'];
    final map = {
      '_source': source ?? fetchSource,
      'query': query,
      'from': offset,
      'size': limit,
      'suggest': suggest,
      'sort': sort,
      if(highlight != null && highlight.isNotEmpty)
        'highlight': highlight,
    };
    map.removeWhere((k, v) => v == null);
    final rs = await _transport.send(new Request('POST', path,
        params: {'search_type': 'dfs_query_then_fetch', if(params != null) ...params}, bodyMap: map));
    if (rs.statusCode != 200) {
      throw new Exception('Failed to search $query, ${rs.body}');
    }
    return _searchResultOf(rs);
  }

  Future<SearchResult> scroll(String scroll, String scrollId) async {
    final path = ['_search', 'scroll'];
    final rs = await _transport.send(new Request('POST', path, bodyMap: {
      "scroll": scroll,
      "scroll_id": scrollId,
    }));
    if (rs.statusCode != 200) {
      throw new Exception('Failed to scroll $scrollId');
    }
    return _searchResultOf(rs);
  }

  SearchResult _searchResultOf(Response rs) {
    final body = convert.json.decode(rs.body);
    final hitsMap = body['hits'] ?? const {};
    final hitsTotal = hitsMap['total'];
    final scrollId = body['_scroll_id'] as String;
    int totalCount = 0;
    if (hitsTotal is int) {
      totalCount = hitsTotal;
    } else if (hitsTotal is Map) {
      totalCount = (hitsTotal['value'] as int) ?? 0;
    }
    final List<Map> hitsList =
        (hitsMap['hits'] as List).cast<Map>() ?? const <Map>[];
    final List<Doc> results = hitsList
        .map((Map map) =>
    new Doc(
      map['_id'] as String,
      map['_source'] as Map<String, dynamic>,
      index: map['_index'] as String,
      type: map['_type'] as String,
      score: map['_score'] as double,
      sort: map['sort'] as List<dynamic>,
      highlight: map['highlight'] as Map<String, dynamic>,
    ))
        .toList();
    final suggestMap = body['suggest'] as Map ?? const {};
    final suggestHits = suggestMap.map<String, List<SuggestHit>>((k, v) {
      if (v == null) return null;
      final list = (v as List).cast<Map>();
      final hits = list
          .map((map) {
        final optionsList = (map['options'] as List).cast<Map>();
        final options = optionsList?.map((m) {
          return new SuggestHitOption(
            m['text'] as String,
            m['score'] as double,
            freq: m['freq'] as int,
            highlighted: m['highlighted'] as String,
          );
        })?.toList();
        return new SuggestHit(
          map['text'] as String,
          map['offset'] as int,
          map['length'] as int,
          options,
        );
      })
          .where((x) => x != null)
          .toList();
      return new MapEntry('', hits);
    });
    suggestHits.removeWhere((k, v) => v == null);
    return new SearchResult(totalCount, results,
        suggestHits: suggestHits.isEmpty ? null : suggestHits, scrollId: scrollId);
  }
}

class SearchResult {
  final int totalCount;
  final List<Doc> hits;
  final Map<String, List<SuggestHit>> suggestHits;
  final String scrollId;

  SearchResult(this.totalCount, this.hits, {this.suggestHits, this.scrollId});

  Map toMap() =>
      {
        'totalCount': totalCount,
        'hits': hits.map((h) => h.toMap()).toList(),
      };
}

class SuggestHit {
  final String text;
  final int offset;
  final int length;
  final List<SuggestHitOption> options;

  SuggestHit(this.text, this.offset, this.length, this.options);
}

class SuggestHitOption {
  final String text;
  final double score;
  final int freq;
  final String highlighted;

  SuggestHitOption(this.text, this.score, {this.freq, this.highlighted});
}

class ElasticDocHit {
  final String id;
  final double score;

  ElasticDocHit(this.id, this.score);

  Map toMap() => {'id': id, 'score': score};
}

abstract class Query {
  static Map matchAll() => {'match_all': {}};

  static Map matchNone() => {'match_none': {}};

  static Map bool({must, filter, should, mustNot}) {
    final map = {};
    if (must != null) map['must'] = must;
    if (filter != null) map['filter'] = filter;
    if (should != null) map['should'] = should;
    if (mustNot != null) map['mustNot'] = mustNot;
    return {'bool': map};
  }

  static Map exists(String field) =>
      {
        'exists': {'field': field}
      };

  static Map term(String field, List<String> terms) =>
      {
        'terms': {field: terms}
      };

  static Map prefix(String field, String value) =>
      {
        'prefix': {field: value},
      };

  static Map match(String field, String text, {String minimum}) {
    final Map map = {'query': text};
    if (minimum != null) {
      map['minimum_should_match'] = minimum;
    }
    return {
      'match': {field: map}
    };
  }
}
