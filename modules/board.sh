#!/usr/bin/env bash

build_tomcat_user_data() {
    local zone="$1"
    local db_endpoint="$2"
    local secret_arn="$3"
    cat <<USERDATA
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-17-jdk tomcat9 awscli jq default-mysql-client libmariadb-java
ln -sf /usr/share/java/mariadb-java-client.jar /var/lib/tomcat9/lib/mariadb-java-client.jar
for attempt in {1..30}; do
  secret="\$(aws secretsmanager get-secret-value --secret-id '$secret_arn' --region '$AWS_REGION' --query SecretString --output text 2>/dev/null || true)"
  [[ -n "\$secret" ]] && break
  sleep 10
done
[[ -n "\$secret" ]] || exit 1
db_user="\$(printf '%s' "\$secret" | jq -r .username)"
db_password="\$(printf '%s' "\$secret" | jq -r .password)"
cat > /usr/share/tomcat9/bin/setenv.sh <<EOF
export BOARD_DB_URL='jdbc:mariadb://$db_endpoint:3306/$DB_NAME'
export BOARD_DB_USER='\$db_user'
export BOARD_DB_PASSWORD='\$db_password'
EOF
chmod 700 /usr/share/tomcat9/bin/setenv.sh
MYSQL_PWD="\$db_password" mysql -h '$db_endpoint' -u "\$db_user" '$DB_NAME' -e "CREATE TABLE IF NOT EXISTS posts (id BIGINT AUTO_INCREMENT PRIMARY KEY,title VARCHAR(200) NOT NULL,author VARCHAR(50) NOT NULL,content TEXT NOT NULL,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP);"
rm -rf /var/lib/tomcat9/webapps/ROOT/*
cat > /var/lib/tomcat9/webapps/ROOT/index.jsp <<'JSP'
<%@ page import="java.sql.*" %><%@ page contentType="text/html; charset=UTF-8" %>
<%! Connection db() throws Exception { Class.forName("org.mariadb.jdbc.Driver"); return DriverManager.getConnection(System.getenv("BOARD_DB_URL"),System.getenv("BOARD_DB_USER"),System.getenv("BOARD_DB_PASSWORD")); } %>
<% request.setCharacterEncoding("UTF-8"); if("POST".equals(request.getMethod())) { try(Connection c=db(); PreparedStatement s=c.prepareStatement("INSERT INTO posts(title,author,content) VALUES(?,?,?)")){s.setString(1,request.getParameter("title"));s.setString(2,request.getParameter("author"));s.setString(3,request.getParameter("content"));s.executeUpdate();} response.sendRedirect("index.jsp"); return; } %>
<!doctype html><html><head><meta charset="utf-8"><title>3Tier Board</title><style>body{margin:0;background:#050a16;color:#eef7ff;font-family:system-ui}main{max-width:900px;margin:48px auto;padding:32px;background:#0e1930;border:1px solid #2d4772;border-radius:20px}input,textarea{width:100%;box-sizing:border-box;margin:7px 0;padding:12px;background:#081326;color:#eef7ff;border:1px solid #2d4772;border-radius:8px}button,a{background:#48c7ff;color:#04111e;border:0;border-radius:8px;padding:10px 14px;text-decoration:none;font-weight:bold}article{padding:16px;margin:12px 0;background:#081326;border-radius:12px}small{color:#9db2ca}</style></head><body><main><h1>3Tier Board</h1><p>ALB → Nginx → Tomcat → RDS MySQL</p><form method="post"><input name="title" placeholder="Title" required><input name="author" placeholder="Author" required><textarea name="content" placeholder="Content" required></textarea><button>Save post</button></form><hr><% try(Connection c=db();Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT id,title,author,content,created_at FROM posts ORDER BY id DESC")){while(r.next()){%><article><b><%=r.getString("title")%></b><small> · <%=r.getString("author")%> · <%=r.getTimestamp("created_at")%></small><p><%=r.getString("content")%></p><a href="delete.jsp?id=<%=r.getLong("id")%>">Delete</a></article><%}} %></main></body></html>
JSP
cat > /var/lib/tomcat9/webapps/ROOT/delete.jsp <<'JSP'
<%@ page import="java.sql.*" %><%! Connection db() throws Exception {Class.forName("org.mariadb.jdbc.Driver");return DriverManager.getConnection(System.getenv("BOARD_DB_URL"),System.getenv("BOARD_DB_USER"),System.getenv("BOARD_DB_PASSWORD"));}%><%try(Connection c=db();PreparedStatement s=c.prepareStatement("DELETE FROM posts WHERE id=?")){s.setLong(1,Long.parseLong(request.getParameter("id")));s.executeUpdate();}response.sendRedirect("index.jsp");%>
JSP
chown -R tomcat:tomcat /var/lib/tomcat9/webapps/ROOT
systemctl enable --now tomcat9
USERDATA
}
