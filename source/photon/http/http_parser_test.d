module http_parser_test;
import photon.http.state_machine, photon.http.http_parser;


unittest {
    int state = 0;
    size_t pos = 0;
    HttpMethod m;
    string s = "GET";
    int result = parseHttpMethod(s, pos, state, m);
    assert(result > 0);
    assert(m == HttpMethod.GET);
    string s2 = "DELE";
    pos = 0;
    state = 0;
    result = parseHttpMethod(s2, pos, state, m);
    assert(result == 0);
    assert(m == HttpMethod.init);
    s2 = "te";
    pos = 0;
    result = parseHttpMethod(s2, pos, state, m);
    assert(result > 0);
    assert(m == HttpMethod.DELETE);
}