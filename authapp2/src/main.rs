use actix_web::middleware::Logger;
use actix_web::{web, App, HttpRequest, HttpServer, Responder};
use env_logger;
use listenfd::ListenFd;
use std::env;

fn index(_req: HttpRequest) -> impl Responder {
    "Hello World!"
}

fn main() {
    let mut listenfd = ListenFd::from_env();
    std::env::set_var("RUST_LOG", "actix_web=info");
    env_logger::init();

    let mut server = HttpServer::new(|| {
        App::new()
            .wrap(Logger::default())
            .route("/", web::get().to(index))
    });

    server = if let Some(l) = listenfd.take_tcp_listener(0).unwrap() {
        println!("starting server");
        server.listen(l).unwrap()
    } else {
        let port = env::var("PORT").unwrap();
        let bind_config = format!("0.0.0.0:{}", port);
        println!("listening on {}", bind_config);
        server.bind(bind_config).unwrap()
    };

    server.run().unwrap();
}
