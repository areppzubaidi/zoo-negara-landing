# Use official Nginx stable on Alpine (lightweight, production-grade)
FROM nginx:1.25-alpine

# Remove default Nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom Nginx configuration
COPY nginx-default.conf /etc/nginx/conf.d/default.conf

# Copy static website files
COPY website/ /usr/share/nginx/html/

# Expose port 80
EXPOSE 80

# Run Nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
