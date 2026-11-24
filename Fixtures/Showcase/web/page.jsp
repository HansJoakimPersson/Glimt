<%@ page contentType="text/html; charset=UTF-8" %>
<!doctype html>
<html>
  <body>
    <h1><%= title %></h1>
    <% if (items != null) { %>
      <p><%= items.size() %> items</p>
    <% } %>
  </body>
</html>
